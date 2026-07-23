"""Tests für den Appcast-Helfer — reine Logik, kein Bauen, kein Netz."""
from __future__ import annotations

import xml.etree.ElementTree as ET

import release_appcast

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _items(xml: str) -> list[ET.Element]:
    root = ET.fromstring(xml)
    return root.findall("./channel/item")


def test_leeres_appcast_erzeugt_geruest_mit_einem_item() -> None:
    xml = release_appcast.upsert_item(
        "", version="0.4.0", url="https://example/TypeLess-0.4.0.zip",
        length=44_000_000, ed_signature="SIG_A", pub_date="Wed, 23 Jul 2026 10:00:00 +0000")
    items = _items(xml)
    assert len(items) == 1
    assert items[0].find(f"{{{SPARKLE}}}version").text == "0.4.0"
    enclosure = items[0].find("enclosure")
    assert enclosure.get("url") == "https://example/TypeLess-0.4.0.zip"
    assert enclosure.get("length") == "44000000"
    assert enclosure.get(f"{{{SPARKLE}}}edSignature") == "SIG_A"


def test_zweite_version_wird_vorn_eingefuegt() -> None:
    erst = release_appcast.upsert_item(
        "", version="0.4.0", url="https://example/TypeLess-0.4.0.zip",
        length=1, ed_signature="SIG_A", pub_date="Wed, 23 Jul 2026 10:00:00 +0000")
    zweit = release_appcast.upsert_item(
        erst, version="0.5.0", url="https://example/TypeLess-0.5.0.zip",
        length=2, ed_signature="SIG_B", pub_date="Thu, 24 Jul 2026 10:00:00 +0000")
    versionen = [i.find(f"{{{SPARKLE}}}version").text for i in _items(zweit)]
    assert versionen == ["0.5.0", "0.4.0"]  # neueste zuerst


def test_dieselbe_version_ist_idempotent() -> None:
    erst = release_appcast.upsert_item(
        "", version="0.4.0", url="https://example/TypeLess-0.4.0.zip",
        length=1, ed_signature="SIG_A", pub_date="Wed, 23 Jul 2026 10:00:00 +0000")
    nochmal = release_appcast.upsert_item(
        erst, version="0.4.0", url="https://example/TypeLess-0.4.0-neu.zip",
        length=999, ed_signature="SIG_NEU", pub_date="Fri, 25 Jul 2026 10:00:00 +0000")
    assert nochmal == erst  # kein zweiter Eintrag, nichts überschrieben
    assert len(_items(nochmal)) == 1
