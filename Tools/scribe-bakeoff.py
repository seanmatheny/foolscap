#!/usr/bin/env python3
"""Compare handwriting recognisers on real Scribe pages.

    python3 Tools/scribe-bakeoff.py [--engines vision,fm,qwen8b,qwen4b] [--pages work-p1,…]
                                    [--helper .build/xcode/Build/Products/Release/FoolscapScribeVLM]
                                    [--models-dir DIR] [--max-side 2480]

Reads Bakeoff/pages.json (which page of which notebook each PNG is), the PNGs in
Bakeoff/pages and the corrected transcripts in Bakeoff/truth, runs each engine,
writes every transcript to Bakeoff/out/<engine>/<page>.txt and prints a table of
word and character error rates and seconds per page. Standard library only.

Engines:
  vision   Apple Vision, taken from the app's OCR cache (Application Support/Foolscap/
           Scribe/OCR, the same reading the transcripts were made from), laid out
           top to bottom; falls back to running .build/debug/FoolscapScribeOCR.
  fm       Apple's on-device Foundation Model via the `fm` CLI (macOS 27).
  qwen8b   Qwen3-VL-8B-Instruct 4-bit through the scribe-vlm helper (MLX).
  qwen4b   Qwen3-VL-4B-Instruct 4-bit through the same helper.
  <engine>@<side>  any of the above at a reduced resolution, e.g. qwen8b@1653.
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BAKEOFF = ROOT / "Bakeoff"
SUPPORT = Path.home() / "Library/Application Support/Foolscap/Scribe"
MODELS = {"qwen8b": "mlx-community/Qwen3-VL-8B-Instruct-4bit", "qwen4b": "mlx-community/Qwen3-VL-4B-Instruct-4bit"}
FM_INSTRUCTIONS = ("You are an OCR engine for handwritten notebook pages. Transcribe every word exactly as "
                   "written, one line per handwritten line, in reading order. Keep bullets and dashes. Do not "
                   "correct, add or summarise anything. Output only the transcription.")

def normalise(text):
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^\w\s'&/.-]", " ", text)
    return text.split()

def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def rates(truth, hypothesis):
    """Sequence WER and CER, plus a bag-of-words error that ignores reading order
    and line joins (two-column pages are read in some order; the truth files pick
    left column first)."""
    tw, hw = normalise(truth), normalise(hypothesis)
    wer = edit_distance(tw, hw) / max(len(tw), 1)
    tc, hc = " ".join(tw), " ".join(hw)
    cer = edit_distance(tc, hc) / max(len(tc), 1)
    from collections import Counter
    missing = sum((Counter(tw) - Counter(hw)).values())
    extra = sum((Counter(hw) - Counter(tw)).values())
    bag = (missing + extra) / 2 / max(len(tw), 1)
    return wer, cer, bag

def vision_from_cache(spec):
    state = json.loads((SUPPORT / "state.json").read_text())
    for item in state["items"].values():
        if item.get("name") == spec["notebook"] and not item.get("isFolder"):
            path = SUPPORT / "OCR" / (item["id"] + ".json")
            if not path.exists():
                return None
            pages = json.loads(path.read_text())["ocr"]["pages"]
            page = pages[spec["page"] - 1]
            obs = sorted(page["observations"], key=lambda o: o["y"] + o["h"] / 2)
            return "\n".join(o["text"] for o in obs)
    return None

def vision_from_helper(spec, pdf):
    helper = ROOT / ".build/debug/FoolscapScribeOCR"
    out = subprocess.run([str(helper), str(pdf)], capture_output=True, text=True, check=True).stdout
    page = json.loads(out)["pages"][spec["page"] - 1]
    obs = sorted(page["observations"], key=lambda o: o["y"] + o["h"] / 2)
    return "\n".join(o["text"] for o in obs)

def run_fm(png):
    cmd = ["fm", "respond", "--no-stream", "-g", "--guardrails", "permissive-content-transformations",
           "--instructions", FM_INSTRUCTIONS, "--image", str(png), "--text", "Transcribe this page."]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout

def run_vlm(helper, model, models_dir, pngs, max_side):
    cmd = [str(helper), "recognise", *map(str, pngs), "--model", model]
    if models_dir: cmd += ["--models-dir", str(models_dir)]
    if max_side: cmd += ["--max-side", str(max_side)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stdout.strip() or proc.stderr.strip())
    result = json.loads(proc.stdout)
    return ["\n".join("  " * l["indent"] + l["text"] for l in p["lines"]) for p in result["pages"]]

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engines", default="vision,fm,qwen8b,qwen4b")
    ap.add_argument("--pages", default=None)
    ap.add_argument("--helper", default=None, help="scribe-vlm binary (default: .build/xcode Release, then Debug, then Foolscap.app)")
    ap.add_argument("--models-dir", default=None)
    ap.add_argument("--max-side", type=int, default=0, help="downscale pages so the longer side is this many pixels")
    ap.add_argument("--scribe", default=str(Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Foolscap/Scribe"))
    ap.add_argument("--score-only", action="store_true", help="re-score the transcripts already in Bakeoff/out without running engines")
    args = ap.parse_args()

    specs = json.loads((BAKEOFF / "pages.json").read_text())
    if args.pages:
        wanted = set(args.pages.split(","))
        specs = [s for s in specs if s["name"] in wanted]
    helper = args.helper and Path(args.helper)
    if not helper:
        for candidate in [ROOT / ".build/xcode/Build/Products/Release/FoolscapScribeVLM",
                          ROOT / ".build/xcode/Build/Products/Debug/FoolscapScribeVLM",
                          ROOT / "Foolscap.app/Contents/MacOS/scribe-vlm"]:
            if candidate.exists():
                helper = candidate; break

    rows = []
    for engine in args.engines.split(","):
        base, _, side = engine.partition("@")
        max_side = int(side) if side else args.max_side
        outdir = BAKEOFF / "out" / engine
        outdir.mkdir(parents=True, exist_ok=True)
        transcripts, seconds = {}, {}
        try:
            if args.score_only:
                for s in specs:
                    path = outdir / (s["name"] + ".txt")
                    if not path.exists(): raise RuntimeError(f"no saved transcript for {s['name']}")
                    transcripts[s["name"]] = path.read_text(); seconds[s["name"]] = float("nan")
            elif base in MODELS:
                if not helper: raise RuntimeError("scribe-vlm helper not built (make scribe-vlm)")
                pngs = [BAKEOFF / "pages" / (s["name"] + ".png") for s in specs]
                t0 = time.time()
                texts = run_vlm(helper, MODELS[base], args.models_dir, pngs, max_side)
                per = (time.time() - t0) / max(len(specs), 1)
                for s, text in zip(specs, texts): transcripts[s["name"]] = text; seconds[s["name"]] = per
            else:
                for s in specs:
                    png = BAKEOFF / "pages" / (s["name"] + ".png")
                    t0 = time.time()
                    if base == "vision":
                        text = vision_from_cache(s) or vision_from_helper(s, Path(args.scribe) / s["pdf"])
                    elif base == "fm":
                        text = run_fm(png)
                    else:
                        raise RuntimeError(f"unknown engine {engine}")
                    transcripts[s["name"]] = text; seconds[s["name"]] = time.time() - t0
        except Exception as error:
            print(f"{engine}: {error}", file=sys.stderr)
            continue
        for s in specs:
            name = s["name"]
            (outdir / (name + ".txt")).write_text(transcripts[name].rstrip() + "\n")
            truth_path = BAKEOFF / "truth" / (name + ".txt")
            if truth_path.exists():
                wer, cer, bag = rates(truth_path.read_text(), transcripts[name])
            else:
                wer = cer = bag = float("nan")
            rows.append((engine, name, wer, cer, bag, seconds[name]))

    print(f"{'engine':<14}{'page':<10}{'WER':>7}{'CER':>7}{'bagWER':>8}{'s/page':>8}")
    for engine, name, wer, cer, bag, sec in rows:
        print(f"{engine:<14}{name:<10}{wer*100:>6.1f}%{cer*100:>6.1f}%{bag*100:>7.1f}%{sec:>8.1f}")
    by_engine = {}
    for engine, _, wer, cer, bag, sec in rows:
        by_engine.setdefault(engine, []).append((wer, cer, bag, sec))
    print()
    for engine, values in by_engine.items():
        n = len(values)
        print(f"{engine:<14}{'mean':<10}{sum(v[0] for v in values)/n*100:>6.1f}%{sum(v[1] for v in values)/n*100:>6.1f}%"
              f"{sum(v[2] for v in values)/n*100:>7.1f}%{sum(v[3] for v in values)/n:>8.1f}")

if __name__ == "__main__":
    main()
