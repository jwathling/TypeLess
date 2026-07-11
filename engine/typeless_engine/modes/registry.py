"""Modus-Definitionen: System-Prompt, Temperatur und Nachrichtenbau je Modus.

Jeder Modus ist ein versioniertes, datengetriebenes Prompt-Template. Ein neuer Modus =
ein neuer ``ModeSpec``-Eintrag, ohne Änderungen am Refiner oder an der Pipeline.

Wichtige, modusübergreifende Leitplanken:
* Sprache beibehalten (Deutsch, Englisch oder gemischt) — niemals übersetzen.
* Nur das Ergebnis ausgeben, keine Erklärungen, keine Meta-Kommentare, keine Code-Fences.
* Bei sehr kurzen Eingaben nichts erfinden.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..models import Mode

# Gemeinsame Leitplanke, die jedem System-Prompt vorangestellt wird.
_GUARDRAIL = (
    "Behalte immer die Ausgangssprache bei (Deutsch, Englisch oder eine Mischung) und "
    "übersetze niemals. Gib ausschließlich das Ergebnis aus — keine Vorbemerkungen, keine "
    "Erklärungen, keine Anführungszeichen um den ganzen Text, keine Code-Fences. Erfinde "
    "keine Fakten, Namen oder Details, die nicht im Eingabetext vorkommen."
)


@dataclass(frozen=True)
class ModeSpec:
    """Vollständige Definition eines Ausgabemodus."""

    mode: Mode
    label: str
    system_prompt: str
    temperature: float = 0.2
    max_tokens: int = 1024
    # Vorlage für die Nutzernachricht; ``{text}`` wird durch den Eingabetext ersetzt.
    user_template: str = "{text}"
    # Ob der Sanity-Check die strikte (Diktat-)Längengrenze anwenden soll.
    strict_length: bool = False
    _guardrail: str = field(default=_GUARDRAIL, repr=False)

    def build_messages(self, text: str) -> list[dict[str, str]]:
        """Baut die Chat-Nachrichten (System + User) für das LLM."""
        return [
            {"role": "system", "content": f"{self.system_prompt}\n\n{self._guardrail}"},
            {"role": "user", "content": self.user_template.format(text=text)},
        ]


MODES: dict[Mode, ModeSpec] = {
    Mode.DIKTAT: ModeSpec(
        mode=Mode.DIKTAT,
        label="Diktat",
        temperature=0.1,
        strict_length=True,
        system_prompt=(
            "Du bist eine Korrektur-Engine für diktierten Text. Korrigiere ausschließlich "
            "Rechtschreibung, Grammatik und Zeichensetzung. Ändere weder Wortwahl noch Stil, "
            "Inhalt oder Bedeutung. Füge nichts hinzu und lasse nichts weg. Entferne lediglich "
            "offensichtliche Sprech-Disfluenzen (z. B. 'ähm', 'äh', doppelte Wörter), wenn sie "
            "klar unbeabsichtigt sind. Setze sinnvolle Absätze und Satzzeichen.\n\n"
            # Die Beispiele sind nicht schmückend: Ohne sie löst 4B nur die auffälligste
            # Korrektur ('nein, Quatsch') auf und lässt 'ich meine' / 'also nicht' stehen.
            "Einzige Ausnahme von 'nichts weglassen': SELBSTKORREKTUREN. Nimmt die sprechende "
            "Person etwas zurück und sagt es neu, dann behalte NUR die zweite (korrigierte) "
            "Fassung. Die erste Fassung und die Korrektur-Wendung selbst fallen ersatzlos weg.\n\n"
            "Beispiele:\n"
            "Eingabe: wir treffen uns am dienstag äh nein quatsch am mittwoch\n"
            "Ausgabe: Wir treffen uns am Mittwoch.\n\n"
            "Eingabe: wir brauchen zehn lizenzen ich meine zwölf lizenzen\n"
            "Ausgabe: Wir brauchen zwölf Lizenzen.\n\n"
            "Eingabe: schick das an tim also nicht an tim an tom\n"
            "Ausgabe: Schick das an Tom.\n\n"
            "Nur bei echter Rücknahme. Ist unklar, ob korrigiert wurde, behalte beide Fassungen."
        ),
    ),
    Mode.PROMPT: ModeSpec(
        mode=Mode.PROMPT,
        label="Prompt",
        temperature=0.3,
        system_prompt=(
            "Formuliere aus dem gesprochenen Gedanken einen klaren, präzisen KI-Prompt, der "
            "sich direkt an ChatGPT oder Claude richten lässt. Der Prompt soll logisch "
            "aufgebaut, strukturiert und vollständig sein: Kontext, konkrete Aufgabe und – wo "
            "sinnvoll – gewünschtes Ausgabeformat. Nutze bei Bedarf kurze Aufzählungen. Bleibe "
            "inhaltlich streng bei dem, was gesagt wurde; ergänze keine erfundenen Anforderungen."
        ),
    ),
    Mode.EMAIL: ModeSpec(
        mode=Mode.EMAIL,
        label="E-Mail",
        temperature=0.3,
        system_prompt=(
            "Wandle den gesprochenen Text in eine professionelle, gut lesbare E-Mail um. "
            "Achte auf höflichen, klaren Ton, sinnvolle Absätze sowie eine passende Anrede und "
            "Grußformel. Halte den Inhalt bei dem, was gesagt wurde. Gib nur den E-Mail-Text "
            "aus (Anrede bis Grußformel); keine Betreffzeile, sofern nicht ausdrücklich diktiert."
        ),
    ),
    Mode.SLACK: ModeSpec(
        mode=Mode.SLACK,
        label="Slack / Teams",
        temperature=0.3,
        system_prompt=(
            "Formuliere den gesprochenen Text als lockere Chat-Nachricht für Slack oder Teams. "
            "Ton: freundlich, direkt und natürlich, nicht übertrieben förmlich. Fasse dich kurz "
            "und klar. Behalte den Inhalt bei; keine steifen Floskeln, keine Grußformeln wie in "
            "einer E-Mail."
        ),
    ),
    Mode.BRAINDUMP: ModeSpec(
        mode=Mode.BRAINDUMP,
        label="Brain Dump",
        temperature=0.3,
        max_tokens=2048,
        system_prompt=(
            "Der Nutzer denkt frei laut. Strukturiere die Gedanken in eine klare, lesbare Notiz: "
            "gruppiere zusammengehörige Themen, entferne Wiederholungen und Füllwörter, und "
            "erzeuge sinnvolle Überschriften. Nutze Markdown-Überschriften und – wo passend – "
            "Aufzählungen. Bewahre alle inhaltlichen Punkte; ordne sie nur klarer an."
        ),
    ),
}


def get_mode_spec(mode: Mode) -> ModeSpec:
    """Liefert die Definition eines Modus."""
    return MODES[mode]
