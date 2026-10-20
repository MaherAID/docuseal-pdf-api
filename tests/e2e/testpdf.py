"""Builds small, valid PDF files for the end-to-end test (no third-party libraries)."""

from __future__ import annotations

A4_WIDTH_PT = 595
A4_HEIGHT_PT = 842


def _escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _page_stream(title: str, boxes: list[tuple[float, float, float, float]]) -> bytes:
    """Content stream: a title line plus outlined boxes given in relative top-left coordinates."""
    lines = ["BT /F1 20 Tf 56 780 Td (" + _escape(title) + ") Tj ET", "0.5 w"]
    for x, y, w, h in boxes:
        # Convert DocuSeal's relative top-left coordinates into PDF points (origin bottom-left).
        left = x * A4_WIDTH_PT
        bottom = A4_HEIGHT_PT - (y + h) * A4_HEIGHT_PT
        lines.append(f"{left:.2f} {bottom:.2f} {w * A4_WIDTH_PT:.2f} {h * A4_HEIGHT_PT:.2f} re S")
    return ("\n".join(lines) + "\n").encode("latin-1")


def build_pdf(pages: list[tuple[str, list[tuple[float, float, float, float]]]]) -> bytes:
    """Return a PDF with one A4 page per (title, boxes) entry."""
    page_count = len(pages)
    page_ids = [4 + 2 * index for index in range(page_count)]
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{' '.join(f'{pid} 0 R' for pid in page_ids)}] /Count {page_count} >>".encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    for index, (title, boxes) in enumerate(pages):
        content_id = page_ids[index] + 1
        objects.append(
            (
                f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {A4_WIDTH_PT} {A4_HEIGHT_PT}] "
                f"/Resources << /Font << /F1 3 0 R >> >> /Contents {content_id} 0 R >>"
            ).encode()
        )
        stream = _page_stream(title, boxes)
        objects.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream")

    output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(output))
        output += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"

    xref_offset = len(output)
    output += f"xref\n0 {len(objects) + 1}\n".encode()
    output += b"0000000000 65535 f \n"
    for offset in offsets:
        output += f"{offset:010d} 00000 n \n".encode()
    output += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n".encode()
    return bytes(output)
