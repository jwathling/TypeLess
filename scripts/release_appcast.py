"""Fügt einen Release-Eintrag in eine Sparkle-`appcast.xml` ein (idempotent).

Reine stdlib — von `scripts/release.sh` aufgerufen, für sich testbar (kein Bauen, kein Netz).
"""
from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

_GERUEST = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    f'<rss version="2.0" xmlns:sparkle="{SPARKLE}">\n'
    "  <channel>\n"
    "    <title>TypeLess</title>\n"
    "  </channel>\n"
    "</rss>\n"
)


def upsert_item(
    appcast_xml: str,
    *,
    version: str,
    url: str,
    length: int,
    ed_signature: str,
    pub_date: str,
) -> str:
    """Fügt vorn einen `<item>` für `version` ein; ist die Version schon da, unverändert zurück."""
    ET.register_namespace("sparkle", SPARKLE)
    root = ET.fromstring(appcast_xml if appcast_xml.strip() else _GERUEST)
    channel = root.find("./channel")
    if channel is None:  # pragma: no cover — nur bei kaputtem Eingabe-XML
        raise ValueError("appcast.xml ohne <channel>")

    for item in channel.findall("item"):
        vorhandene = item.find(f"{{{SPARKLE}}}version")
        if vorhandene is not None and vorhandene.text == version:
            return appcast_xml  # idempotent: bereits veröffentlicht

    item = ET.Element("item")
    ET.SubElement(item, "title").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, "pubDate").text = pub_date
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", url)
    enclosure.set("type", "application/octet-stream")
    enclosure.set("length", str(length))
    enclosure.set(f"{{{SPARKLE}}}edSignature", ed_signature)

    # Neueste Version zuerst: direkt hinter <title> (dem ersten Kind des Channels) einsetzen.
    channel.insert(1, item)
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="unicode", xml_declaration=True) + "\n"


def main() -> None:
    p = argparse.ArgumentParser(description="Appcast-Eintrag einfügen (idempotent).")
    p.add_argument("appcast")
    p.add_argument("--version", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", type=int, required=True)
    p.add_argument("--ed-signature", required=True)
    p.add_argument("--pub-date", required=True)
    p.add_argument("--stdout", action="store_true", help="nur ausgeben, Datei nicht schreiben")
    args = p.parse_args()

    try:
        with open(args.appcast, encoding="utf-8") as f:
            bestehend = f.read()
    except FileNotFoundError:
        bestehend = ""

    ergebnis = upsert_item(
        bestehend, version=args.version, url=args.url, length=args.length,
        ed_signature=args.ed_signature, pub_date=args.pub_date)

    if args.stdout:
        print(ergebnis, end="")
    else:
        with open(args.appcast, "w", encoding="utf-8") as f:
            f.write(ergebnis)


if __name__ == "__main__":
    main()
