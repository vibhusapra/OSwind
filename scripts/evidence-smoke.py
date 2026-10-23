#!/usr/bin/env python3
"""Long, shared-prefix evidence and follow-ups through real CLI processes."""
import argparse, datetime, hashlib, json, pathlib, re, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument("binary", nargs="?", default=".build/debug/oswindctl")
parser.add_argument("--provider", choices=["evidence", "apple", "ollama"], default="evidence")
parser.add_argument("--output")
parser.add_argument("--model", default="qwen3:4b-instruct-2507-q4_K_M")
parser.add_argument("--abstention", action="store_true", help="Also check an explicitly unsupported budget question with a local model")
options = parser.parse_args()
binary = pathlib.Path(options.binary).resolve()
boilerplate = "Zephyr release background. Routine project notes and repeated application chrome.\n" * 120
sources = [boilerplate + "North Zephyr release owner is Lina. North deadline is Thursday.",
           boilerplate + "South Zephyr release owner is Theo. South deadline is Monday."]
report = {"fixture": "long-shared-prefix-v1", "provider": options.provider, "model": options.model if options.provider == "ollama" else options.provider,
          "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "source_utf8_bytes": [len(text.encode()) for text in sources],
          "source_sha256": [hashlib.sha256(text.encode()).hexdigest() for text in sources],
          "scope": "Two fictional long notes and two questions; authored regression smoke, not held-out grounding or abstention accuracy."}

with tempfile.TemporaryDirectory(prefix="oswind-long-evidence-") as directory:
    prefix = [str(binary), "--data", directory]
    def cli(*args): return subprocess.run(prefix + list(args), text=True, timeout=90, check=True, capture_output=True).stdout
    identifiers = [cli("note", text).strip() for text in sources]
    if options.provider == "ollama":
        models = json.loads(cli("models", "list"))
        report["model_metadata"] = next((model for model in models if model["name"] == options.model), None)
    session = json.loads(cli("chat", "new"))["id"]
    def ask(question):
        try: return json.loads(cli("chat", "ask", session, "--provider", options.provider, *(["--model", options.model] if options.provider == "ollama" else []), question))["answer"]
        except subprocess.CalledProcessError as error:
            report.setdefault("errors", []).append({"question": question, "message": error.stderr.strip()})
            return {"text": "", "provider": options.provider, "duration": 0, "warnings": [error.stderr.strip()], "sources": []}
    first = ask("Who owns the North and South Zephyr releases?")
    followup = ask("What are their deadlines?")
    def binding(text, subject, value):
        # Narrow fixture grader: names/values must share a clause, without
        # crossing another subject. Merely containing both names is insufficient.
        between = r"(?:(?!\b(?:North|South|Lina|Theo)\b)[^.!?\n]){0,100}"
        return re.search(r"\b" + subject + r"\b" + between + r"\b" + value + r"\b", text, re.I) is not None or re.search(r"\b" + value + r"\b\s+(?:owns|is (?:the )?owner of|is responsible for)\b" + between + r"\b" + subject + r"\b", text, re.I) is not None
    assert binding("North owner is Lina [1], South owner is Theo [2].", "North", "Lina")
    assert not binding("North owner is Lina [1], South owner is Theo [2].", "South", "Lina")
    assert binding("South owner is Lina [1].", "South", "Lina")  # Detect the rejected experiment's false claim.
    def compact(answer):
        return {key: answer[key] for key in ["text", "provider", "duration", "warnings"]} | {"source_ids": [hit["memory"]["id"] for hit in answer["sources"]]}
    report |= {"first": compact(first), "followup": compact(followup)}
    checks = {"both_distinct_sources": all(set(answer["source_ids"]) == set(identifiers) for answer in [report["first"], report["followup"]]),
              "both_owners": all(name in first["text"] for name in ["Lina", "Theo"]),
              "both_deadlines": all(day in followup["text"] for day in ["Thursday", "Monday"]),
              "correct_owner_bindings": binding(first["text"],"North","Lina") and binding(first["text"],"South","Theo") and not binding(first["text"],"North","Theo") and not binding(first["text"],"South","Lina"),
              "correct_deadline_bindings": any(binding(followup["text"],subject,"Thursday") for subject in ["North","Lina"]) and any(binding(followup["text"],subject,"Monday") for subject in ["South","Theo"]) and not any(binding(followup["text"],subject,"Monday") for subject in ["North","Lina"]) and not any(binding(followup["text"],subject,"Thursday") for subject in ["South","Theo"]),
              "bounded_excerpt_warning": all(any("bounded excerpts" in warning for warning in answer["warnings"]) for answer in [first, followup]),
              "citations": all("[1]" in answer["text"] and "[2]" in answer["text"] for answer in [first, followup]),
              "reopened_turns": len(json.loads(cli("chat", "show", session))["turns"]) == 2}
    if options.abstention:
        assert options.provider != "evidence", "Evidence-only mode lists sources; it does not generate an abstention decision"
        absent = ask("What are their launch budget amounts in USD? If not recorded, say insufficient evidence.")
        report["unanswerable"] = compact(absent)
        checks["unsupported_budget_abstention"] = any(phrase in absent["text"].lower() for phrase in ["insufficient", "couldn’t find", "could not", "not recorded", "not provided", "do not", "does not", "no recorded"])
        checks["no_invented_budget"] = re.search(r"\$\s*\d|\b\d[\d,.]*\s*(?:USD|dollars)", absent["text"], re.I) is None
    if options.provider != "evidence":
        outputs = [first, followup] + ([absent] if options.abstention else [])
        checks["concise_final_answers"] = all(0 < len(answer["text"]) < 1600 and not any(phrase in answer["text"].lower() for phrase in ["the instruction says", "we are given", "let's write", "we must answer"]) for answer in outputs)
    checks["no_inference_errors"] = not report.get("errors")
    report["checks"] = checks
    if options.output:
        pathlib.Path(options.output).write_text(json.dumps(report, indent=2) + "\n")
    assert all(checks.values()), report
    print("PASS: long-source excerpts, distinct shared-prefix sources, owner/deadline follow-up, citations, durable reopen (" + options.provider + ")")
