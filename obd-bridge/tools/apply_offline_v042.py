from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing patch target: {label}")
    return text.replace(old, new, 1)


completion = Path("obd-bridge/OBDBridge/ProfessionalDiagnosticsCompletion.swift")
text = completion.read_text()
text = text.replace('OBDBridge-iOS/0.4', 'OBDBridge-iOS/0.4.2')
text = replace_once(
    text,
    '''            } catch {
                await MainActor.run {
                    self.isAnalyzing = false
                    self.lastError = error.localizedDescription
                    self.status = "AI analysis failed"
                }
            }
''',
    '''            } catch {
                let cloudError = error
                do {
                    let local = try LocalOBDAnalysisEngine.analyze(snapshotURL: snapshotURL)
                    await MainActor.run {
                        self.isAnalyzing = false
                        self.summary = local.summary
                        self.status = "On-device expert analysis saved"
                        self.lastAnalysisURL = local.url
                        self.lastError = "Cloud analysis unavailable: \\(cloudError.localizedDescription)"
                    }
                } catch {
                    await MainActor.run {
                        self.isAnalyzing = false
                        self.lastError = "Cloud: \\(cloudError.localizedDescription) · Local: \\(error.localizedDescription)"
                        self.status = "Diagnostic analysis failed"
                    }
                }
            }
''',
    "analysis fallback catch",
)
completion.write_text(text)

project = Path("obd-bridge/project.yml")
text = project.read_text()
text = text.replace('CFBundleShortVersionString: "0.4.1"', 'CFBundleShortVersionString: "0.4.2"')
text = text.replace('CFBundleVersion: "7"', 'CFBundleVersion: "8"')
text = text.replace('MARKETING_VERSION: "0.4.1"', 'MARKETING_VERSION: "0.4.2"')
text = text.replace('CURRENT_PROJECT_VERSION: "7"', 'CURRENT_PROJECT_VERSION: "8"')
project.write_text(text)

plist = Path("obd-bridge/OBDBridge/Info.plist")
text = plist.read_text()
text = text.replace('<string>0.4.1</string>', '<string>0.4.2</string>')
text = text.replace('<string>7</string>', '<string>8</string>', 1)
plist.write_text(text)

Path(__file__).unlink()
