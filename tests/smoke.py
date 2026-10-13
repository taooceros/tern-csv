"""Smoke-test the plugin in real Tern; needs a desktop session.

Runs an isolated Tern (its own config folder, daemon and control socket, so
your own Tern and plugins are untouched), links this folder as a plugin,
opens CSV fixtures through the "Open CSV…" command and the open route, and
checks what the block draws and its Table | Text round trip through Tern's
file block.
Screenshots go to .dev/shots/.

    python3 tests/smoke.py
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TERN = os.environ.get("TERN", shutil.which("tern") or "/Applications/Tern.app/Contents/MacOS/tern")
ARTIFACTS = ROOT / ".dev"
ARTIFACTS.mkdir(exist_ok=True)
MAIN = ".sf-main[data-surface='plugin.csv.table']"
DOCK = ".sf-dock[data-surface='plugin.csv.table']"
CELLS = f"{MAIN} .sf-tbl-c"


def fixtures(data: Path):
    data.mkdir()
    shutil.copy(ROOT / "sample.csv", data / "sample.csv")
    (data / "bad.csv").write_text('id,name\n1,"never closed\n2,x\n', encoding="utf-8")
    (data / "empty.csv").write_text("", encoding="utf-8")
    (data / "latin1.csv").write_bytes("city,country\nZ\u00fcrich,CH\n".encode("latin-1"))
    (data / "people.tsv").write_bytes(
        b'name\tteam\tnote\r\nAda\tEngines\t"tab\there"\r\nGrace\tCompilers\t"multi\r\nline"\r\nLinus\r\n'
    )
    with (data / "zz-huge.csv").open("w", encoding="utf-8") as f:
        row = "x" * 1023 + "\n"
        for _ in range(5 * 1024):
            f.write(row)
    with (data / "long.csv").open("w", encoding="utf-8") as f:
        f.write(",".join(f"field_{c:02d}" for c in range(1, 19)) + "\n")
        for r in range(1, 301):
            f.write(",".join(f"r{r}c{c}" for c in range(1, 19)) + "\n")
    (data / "link.csv").symlink_to(data / "sample.csv")
    (data / "readme.txt").write_text("not a table\n", encoding="utf-8")


def publish(out: Path):
    """Copies a run's shots and logs into .dev/ once Tern has stopped. They are written outside
    while Tern runs: Tern watches the linked plugin folder and reloads the plugin on any change
    there, which restarts the block and can drop keys sent meanwhile."""
    for name in ("shots", "smoke-logs"):
        shutil.rmtree(ARTIFACTS / name, ignore_errors=True)
        if (out / name).exists():
            shutil.copytree(out / name, ARTIFACTS / name)
    shutil.copy(out / "smoke-process.log", ARTIFACTS / "smoke-process.log")


with tempfile.TemporaryDirectory(prefix="tern-csv-", dir="/tmp") as temporary:
    work = Path(temporary)
    data = work / "data"
    fixtures(data)
    config = work / "config"
    config.mkdir()
    zdot = work / "zsh"
    zdot.mkdir()
    (zdot / ".zshrc").write_text("PROMPT='%~ %# '\n", encoding="utf-8")
    out = work / "artifacts"
    out.mkdir()
    env = dict(os.environ, TERN_CONFIG_DIR=str(config),
               TERN_DAEMON_SOCKET=str(work / "daemon.sock"),
               STENCIL_LOG_DIR=str(out / "smoke-logs"),
               ZDOTDIR=str(zdot))
    link = subprocess.run([TERN, "plugin", "link", str(ROOT)], env=env, check=True,
                          text=True, capture_output=True)
    print("$ tern plugin link .\n" + link.stdout.strip())
    control = str(work / "control.sock")

    def ctl(command):
        result = subprocess.run([TERN, "ctl", "--control", control, command],
                                env=env, text=True, capture_output=True, timeout=40)
        reply = json.loads(result.stdout)
        assert result.returncode == 0 and reply["ok"], (command, reply)
        return reply

    def texts(selector):
        return [n.get("text", "") for n in ctl(f"tree {selector}")["nodes"]]

    def wait_text(selector, needle, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            found = texts(selector)
            if any(needle in t for t in found):
                return found
            assert time.monotonic() < deadline, (selector, needle, found)
            time.sleep(0.2)

    def mode():
        """The switch's buttons and the pressed one, by their titles."""
        shown = [n.get("title") for n in ctl("tree .csv-mode")["nodes"]]
        pressed = [n.get("title") for n in ctl("tree .csv-mode[aria-pressed='true']")["nodes"]]
        return shown, pressed

    def sides():
        """The active tab's pane count, whether Tern's file block shows sample.csv, and whether the
        table block shows its cells."""
        state = ctl("state")
        panes = next(t["panes"] for t in state["tabs"] if t["active"])
        editor = any(f["path"].endswith("/sample.csv") for f in state.get("file_blocks", []))
        return panes, editor, bool(texts(CELLS))

    def wait_sides(want, why, timeout=15):
        deadline = time.monotonic() + timeout
        while sides() != want:
            assert time.monotonic() < deadline, (why, want, sides())
            time.sleep(0.2)

    def keys(*combos):
        for combo in combos:
            ctl(f"key {combo}")

    with (out / "smoke-process.log").open("w") as log:
        daemon = subprocess.Popen([TERN, "daemon"], env=env, stdout=log, stderr=log)
        window = None
        try:
            deadline = time.monotonic() + 30
            while not Path(env["TERN_DAEMON_SOCKET"]).exists():
                assert daemon.poll() is None, "daemon exited; see .dev/smoke-process.log"
                assert time.monotonic() < deadline, "daemon did not open its socket"
                time.sleep(0.1)
            window = subprocess.Popen([TERN, "--control", control, "--out", str(out / "shots"),
                                       str(data)], env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while not Path(control).exists():
                assert window.poll() is None, "Tern exited; see .dev/smoke-process.log"
                assert time.monotonic() < deadline, "Tern did not open its control endpoint"
                time.sleep(0.1)
            ctl("ready")
            catalog = json.loads(subprocess.run([TERN, "plugin", "reload", "--json"], env=env, check=True,
                                                text=True, capture_output=True).stdout)
            assert not catalog["problems"], catalog
            csv = [p for p in catalog["plugins"] if p["id"] == "csv"]
            assert csv and csv[0]["status"] == "ready", catalog
            print("PASS: plugin csv loads (status ready, no problems)")

            ctl(f'run "cd {data}"')
            ctl("plugins run plugin.csv.open")
            found = wait_text(MAIN, "sample.csv")
            assert any("people.tsv" in t for t in found) and not any("readme.txt" in t for t in found), found
            ctl("shot csv-picker")
            print("PASS: Open CSV… lists the folder's .csv/.tsv files only")

            def pick(name):
                """From the picker: select `name` (files are sorted), a key at a time, and open it."""
                names = sorted(p.name for p in data.iterdir() if p.suffix in (".csv", ".tsv"))
                keys("Home")
                wait_text(f"{MAIN} .sel", names[0])
                for i in range(1, names.index(name) + 1):
                    keys("ArrowDown")
                    wait_text(f"{MAIN} .sel", names[i])
                keys("Enter")

            pick("sample.csv")
            wait_text(DOCK, "12 rows")
            dock = texts(DOCK)
            assert any("6 columns" in t for t in dock), dock
            assert any("1 short row padded" in t for t in dock), dock
            ctl("shot csv-table")
            cells = texts(CELLS) + texts(f"{MAIN} .sf-tbl-h")
            for needle in ("Ada Lovelace", "Arlington, VA", "Murray Hill", "score"):
                assert any(needle in t for t in cells), (needle, cells)
            print("PASS: sample.csv renders 12 rows x 6 columns; quoted commas, 1 ragged row padded")

            keys("ArrowDown", "ArrowDown", "ArrowRight")
            wait_text(DOCK, "Row 3 of 12 · name: Alan Turing")
            keys("j", "l", "l")
            wait_text(DOCK, "Row 4 of 12 · joined: 1959-01-01")
            ctl('type "$"')
            wait_text(DOCK, "Row 4 of 12 · notes: (empty)")
            # The notes column sits past the pane's edge: the sheet scrolls sideways natively.
            ctl(f"hover {MAIN} .csv-sheet")
            ctl("wheel 3000 0")
            for needle in ('Popularized the term "bug"', "Two lines:↵On Computable Numbers"):
                wait_text(CELLS, needle)
            keys("ArrowUp")
            wait_text(DOCK, "Row 3 of 12 · notes: Two lines:↵On Computable Numbers")
            ctl("shot csv-cursor")
            keys("End")
            wait_text(DOCK, "Row 12 of 12")
            keys("g", "0")
            wait_text(DOCK, "Row 1 of 12 · id: 1")
            print("PASS: arrows, hjkl, $, End and g/0 move the cursor cell; escaped quotes and embedded newline shown")

            keys("Backspace")
            wait_text(MAIN, "CSV and TSV files in")
            pick("bad.csv")
            wait_text(MAIN, "bad.csv is not valid CSV")
            wait_text(MAIN, "quoted field is never closed")
            ctl("shot csv-parse-error")
            print("PASS: an unclosed quote shows a parse error with its location")

            keys("Backspace")
            pick("empty.csv")
            wait_text(MAIN, "empty.csv is empty")
            print("PASS: an empty file shows a notice")

            keys("Backspace")
            pick("long.csv")
            wait_text(DOCK, "300 rows")
            cells = wait_text(CELLS, "r1c1")
            ctl("shot csv-long")
            shown = [t for t in cells if t.startswith("r") and t.endswith("c1")]
            # The rows fill the pane down to the dock, whatever height Tern reports to the block
            # (24 rows here): fully shown rows end less than one row above the dock.
            dock_top = min(n["rect"][1] for n in ctl(f"tree {DOCK} .sf-text")["nodes"])
            bottoms = [n["rect"][1] + n["rect"][3] for n in ctl(f"tree {CELLS}")["nodes"]
                       if n.get("text", "").endswith("c1") and n["rect"][1] + n["rect"][3] <= dock_top]
            assert shown[0] == "r1c1" and len(bottoms) > 15 and dock_top - max(bottoms) < 22, (len(bottoms), dock_top, max(bottoms))
            assert shown == [f"r{i}c1" for i in range(1, len(shown) + 1)], shown
            keys("PageDown")
            deadline = time.monotonic() + 10
            while (row := int(" ".join(texts(DOCK)).split("Row ")[1].split(" of")[0])) == 1:
                assert time.monotonic() < deadline, "PageDown did not move the cursor"
                time.sleep(0.2)
            wait_text(CELLS, f"r{row}c1")
            keys("End")
            wait_text(CELLS, "r300c1")
            assert "r1c1" not in texts(CELLS)
            ctl('type "$"')
            wait_text(DOCK, "field_18: r300c18")
            keys("g")
            wait_text(CELLS, "r1c1")
            print(f"PASS: long.csv fills the pane ({len(bottoms)} rows shown); PageDown, End and g scroll the cursor row into view")

            def header_x(name):
                return next(n["rect"][0] for n in ctl(f"tree {MAIN} .sf-tbl-h")["nodes"] if n.get("text") == name)
            sheet = ctl(f"tree {MAIN} .csv-sheet")["nodes"][0]["rect"]
            right = sheet[0] + sheet[2]
            assert header_x("field_18") > right, ("all 18 columns render, past the pane's right edge", header_x("field_18"), right)
            ctl(f"hover {MAIN} .csv-sheet")
            ctl("wheel 3000 0")
            deadline = time.monotonic() + 10
            while header_x("field_18") > right:
                assert time.monotonic() < deadline, ("a sideways wheel scrolls the sheet", header_x("field_18"), right)
                time.sleep(0.2)
            ctl("shot csv-long-scrolled-right")
            print("PASS: long.csv renders all 18 columns; the sheet scrolls sideways to the last one")

            keys("Backspace")
            pick("zz-huge.csv")
            wait_text(MAIN, "zz-huge.csv is too large")
            wait_text(MAIN, "CSV Table reads files up to 4.0 MiB. Open it as text instead.")
            print("PASS: a 5 MiB file is refused with a size notice")

            keys("Backspace")
            pick("link.csv")
            wait_text(DOCK, "12 rows")
            # Made only now: a FIFO in the folder from the start stalls Tern's own startup reads.
            os.mkfifo(data / "pipe.csv")
            keys("Backspace")
            pick("pipe.csv")
            wait_text(MAIN, "is not a regular file")
            print("PASS: a symlinked CSV opens through its target; a FIFO is refused without hanging")

            keys("Backspace")
            pick("latin1.csv")
            wait_text(MAIN, "Zürich")
            wait_text(DOCK, "read as Latin-1")
            print("PASS: a Latin-1 file is decoded and flagged")

            keys("Backspace")
            pick("people.tsv")
            wait_text(DOCK, "3 rows")
            dock = texts(DOCK)
            assert any("TSV" in t for t in dock) and any("1 short row padded" in t for t in dock), dock
            for needle in ("Engines", "tab here", "multi↵line"):
                wait_text(MAIN, needle)
            print("PASS: people.tsv (CRLF, quoted tab and line break) parses as TSV")

            ctl("tab new")
            ctl("ready")
            ctl(f'run "cd {data} && tern open sample.csv"')
            wait_text(DOCK, "12 rows")
            assert ctl("state")["focused"]["label"] == "sample.csv"
            print("PASS: `tern open sample.csv` routes to the CSV Table block")

            panes = sides()[0]
            assert mode() == (["Table", "Text"], ["Table"]), mode()
            assert sides() == (panes, False, True), sides()
            ctl("shot csv-switch-table")
            ctl("click .csv-mode[data-mode='text']")
            wait_sides((panes, True, False), "Text puts Tern's file block in the table's place")
            time.sleep(1)
            assert sides() == (panes, True, False), ("the file block was routed back to a table", sides())
            ctl("file wait")
            assert ctl("state")["focused"]["label"] == "sample.csv"
            ctl("shot csv-switch-text")
            keys("ctrl+alt+t")
            wait_sides((panes, False, True), "⌃⌥T puts the table back in the file block's place")
            wait_text(DOCK, "12 rows")
            keys("t")
            wait_sides((panes, True, False), "t opens Text in the table's place")
            ctl("plugins run plugin.csv.show_table")
            wait_sides((panes, False, True), "Show CSV as table puts the table back")
            wait_text(DOCK, "12 rows")
            print("PASS: sample.csv opens on Table; Text (click, t) swaps in Tern's file block in place, "
                  "and Show CSV as table (⌃⌥T, palette) swaps the table back")

            with (data / "sample.csv").open("a", encoding="utf-8") as f:
                f.write("13,Linus Torvalds,Portland,1991-08-25,91,Linux\n")
            keys("r")
            wait_text(DOCK, "13 rows")
            keys("End")
            wait_text(CELLS, "Linus Torvalds")
            (data / "sample.csv").unlink()
            keys("r")
            wait_text(MAIN, "sample.csv was not found")
            ctl("shot csv-missing")
            print("PASS: r reloads changes, and a deleted file shows 'not found'")

            # Opens that used to reach the editor now show the table too.
            ctl("tab new")
            ctl("ready")
            ctl('run "clear"')
            ctl(f'run "echo {data}/long.csv:5"')
            ctl('expect "long.csv:5"')
            ctl("click 60 74 meta")  # ⌘-click the printed path (row 2 of the cleared pane)
            wait_text(DOCK, "Row 4 of 300")
            assert ctl("state")["focused"]["label"] == "long.csv"
            print("PASS: ⌘-clicking long.csv:5 in a terminal opens the table on the row holding line 5")
            ctl(f"file open {data}/people.tsv preview")
            wait_text(DOCK, "3 rows")
            state = ctl("state")
            assert state["focused"]["label"] == "people.tsv" and not state.get("file_blocks"), state.get("file_blocks")
            ctl("shot csv-preview-open")
            print("PASS: a preview open of people.tsv opens the table, not the editor")
        finally:
            if window is not None and window.poll() is None:
                window.terminate()
                window.wait(timeout=15)
            if daemon.poll() is None:
                daemon.terminate()
                daemon.wait(timeout=15)
            publish(out)
