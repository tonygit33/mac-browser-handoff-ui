from pathlib import Path

path = Path("obd-bridge/OBDBridge/ScanPlanner.swift")
text = path.read_text()
old = """                    (requirement.required ? missingRequired : missingOptional).append(requirement.signal)
"""
new = """                    if requirement.required {
                        missingRequired.append(requirement.signal)
                    } else {
                        missingOptional.append(requirement.signal)
                    }
"""
count = text.count(old)
if count != 2:
    raise RuntimeError(f"expected 2 conditional append sites, found {count}")
text = text.replace(old, new)
text = text.replace("required: group.contains(where: \\.required),", "required: group.contains(where: { $0.required }),")
path.write_text(text)
Path(__file__).unlink()
