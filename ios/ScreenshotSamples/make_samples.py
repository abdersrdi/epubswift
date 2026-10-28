"""Builds the sample EPUBs used for App Store screenshots (public-domain text, generated covers).

Run on Windows:  python make_samples.py
The .epub files are copied into the app only by the screenshots workflow, never into the App Store build.
"""
import io
import os
import textwrap
import uuid
import zipfile

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_B = r"C:\Windows\Fonts\georgiab.ttf"
FONT_R = r"C:\Windows\Fonts\georgia.ttf"

BOOKS = [
    {
        "file": "01-alice.epub", "title": "Alice's Adventures in Wonderland", "author": "Lewis Carroll",
        "colors": ((0x1F, 0x6F, 0x8B), (0x99, 0xD4, 0xC4)),
        "chapters": [
            ("Down the Rabbit-Hole", [
                "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, “and what is the use of a book,” thought Alice, “without pictures or conversations?”",
                "So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.",
                "There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself, “Oh dear! Oh dear! I shall be late!” (when she thought it over afterwards, it occurred to her that she ought to have wondered at this, but at the time it all seemed quite natural); but when the Rabbit actually took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it, and burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge.",
                "In another moment down went Alice after it, never once considering how in the world she was to get out again.",
                "The rabbit-hole went straight on like a tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a moment to think about stopping herself before she found herself falling down a very deep well.",
                "Either the well was very deep, or she fell very slowly, for she had plenty of time as she went down to look about her and to wonder what was going to happen next. First, she tried to look down and make out what she was coming to, but it was too dark to see anything; then she looked at the sides of the well, and noticed that they were filled with cupboards and book-shelves; here and there she saw maps and pictures hung upon pegs.",
            ]),
            ("The Pool of Tears", [
                "“Curiouser and curiouser!” cried Alice (she was so much surprised, that for the moment she quite forgot how to speak good English); “now I’m opening out like the largest telescope that ever was! Good-bye, feet!”",
                "Just then her head struck against the roof of the hall: in fact she was now rather more than nine feet high, and she at once took up the little golden key and hurried off to the garden door.",
            ]),
            ("A Caucus-Race and a Long Tale", [
                "They were indeed a queer-looking party that assembled on the bank, the birds with draggled feathers, the animals with their fur clinging close to them, and all dripping wet, cross, and uncomfortable.",
            ]),
        ],
    },
    {
        "file": "02-pride.epub", "title": "Pride and Prejudice", "author": "Jane Austen",
        "colors": ((0x8B, 0x2E, 0x4A), (0xF0, 0xB6, 0x9A)),
        "chapters": [("Chapter 1", [
            "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
            "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters.",
        ])],
    },
    {
        "file": "03-frankenstein.epub", "title": "Frankenstein", "author": "Mary Shelley",
        "colors": ((0x1B, 0x2B, 0x1F), (0x6F, 0xA0, 0x7C)),
        "chapters": [("Letter 1", [
            "You will rejoice to hear that no disaster has accompanied the commencement of an enterprise which you have regarded with such evil forebodings.",
            "I arrived here yesterday, and my first task is to assure my dear sister of my welfare and increasing confidence in the success of my undertaking.",
        ])],
    },
    {
        "file": "04-moby.epub", "title": "Moby-Dick", "author": "Herman Melville",
        "colors": ((0x0B, 0x2A, 0x4A), (0x4C, 0x8F, 0xC9)),
        "chapters": [("Loomings", [
            "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world.",
            "It is a way I have of driving off the spleen and regulating the circulation.",
        ])],
    },
    {
        "file": "05-meditations.epub", "title": "Meditations", "author": "Marcus Aurelius",
        "colors": ((0x4A, 0x3B, 0x2A), (0xD9, 0xB9, 0x7A)),
        "chapters": [("Book 2", [
            "Begin the morning by saying to thyself, I shall meet with the busy-body, the ungrateful, arrogant, deceitful, envious, unsocial.",
            "All these things happen to them by reason of their ignorance of what is good and evil.",
        ])],
    },
    {
        "file": "06-artofwar.epub", "title": "The Art of War", "author": "Sun Tzu",
        "colors": ((0x6B, 0x14, 0x1B), (0xE8, 0x7B, 0x55)),
        "chapters": [("Laying Plans", [
            "Sun Tzu said: The art of war is of vital importance to the State.",
            "It is a matter of life and death, a road either to safety or to ruin. Hence it is a subject of inquiry which can on no account be neglected.",
        ])],
    },
]


def cover(book):
    w, h = 800, 1200
    top, bottom = book["colors"]
    img = Image.new("RGB", (w, h), top)
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    d = ImageDraw.Draw(img)
    d.rectangle((40, 40, w - 40, h - 40), outline=(255, 255, 255), width=4)
    title_font = ImageFont.truetype(FONT_B, 78)
    lines = []
    for para in textwrap.wrap(book["title"], width=14):
        lines.append(para)
    y = 300
    for line in lines:
        tw = d.textlength(line, font=title_font)
        d.text(((w - tw) / 2, y), line, font=title_font, fill=(255, 255, 255))
        y += 96
    d.line((w / 2 - 90, y + 24, w / 2 + 90, y + 24), fill=(255, 255, 255), width=4)
    author_font = ImageFont.truetype(FONT_R, 44)
    tw = d.textlength(book["author"], font=author_font)
    d.text(((w - tw) / 2, h - 220), book["author"], font=author_font, fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=88)
    return buf.getvalue()


def xhtml(title, body):
    return ('<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><meta charset="utf-8"/>'
            f'<title>{title}</title><link rel="stylesheet" href="style.css"/></head><body>\n{body}\n</body></html>\n')


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build(book):
    path = os.path.join(HERE, book["file"])
    uid = "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, book["title"]))
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                   '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
                   compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/style.css", "body{font-family:serif;line-height:1.6;margin:5%;}h1{font-size:1.6em;margin:1.2em 0 .8em;}p{margin:0 0 1em;text-indent:0;}",
                   compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/cover.jpg", cover(book), compress_type=zipfile.ZIP_STORED)
        manifest, spine, nav_items, ncx_items = "", "", "", ""
        for i, (title, paras) in enumerate(book["chapters"], start=1):
            name = f"ch{i}.xhtml"
            body = f"<h1>{esc(title)}</h1>\n" + "\n".join(f"<p>{esc(p)}</p>" for p in paras)
            z.writestr("OEBPS/" + name, xhtml(esc(title), body), compress_type=zipfile.ZIP_DEFLATED)
            manifest += f'<item id="c{i}" href="{name}" media-type="application/xhtml+xml"/>\n'
            spine += f'<itemref idref="c{i}"/>\n'
            nav_items += f'<li><a href="{name}">{esc(title)}</a></li>\n'
            ncx_items += (f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>{esc(title)}</text></navLabel>'
                          f'<content src="{name}"/></navPoint>\n')
        z.writestr("OEBPS/nav.xhtml", xhtml("Contents", f'<nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><h1>Contents</h1><ol>\n{nav_items}</ol></nav>'),
                   compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx",
                   f'<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
                   f'<head><meta name="dtb:uid" content="{uid}"/></head><docTitle><text>{esc(book["title"])}</text></docTitle>'
                   f'<navMap>{ncx_items}</navMap></ncx>', compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf",
                   f'<?xml version="1.0" encoding="utf-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">\n'
                   f'<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">{uid}</dc:identifier>'
                   f'<dc:title>{esc(book["title"])}</dc:title><dc:creator>{esc(book["author"])}</dc:creator><dc:language>en</dc:language>'
                   f'<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta><meta name="cover" content="cover-image"/></metadata>\n'
                   f'<manifest>\n<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
                   f'<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n<item id="css" href="style.css" media-type="text/css"/>\n'
                   f'<item id="cover-image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>\n{manifest}</manifest>\n'
                   f'<spine toc="ncx">\n{spine}</spine>\n</package>', compress_type=zipfile.ZIP_DEFLATED)
    print("wrote", book["file"], os.path.getsize(path), "bytes")


if __name__ == "__main__":
    for b in BOOKS:
        build(b)
