"""Text shaping for speech: markdown stripping, chunking, block timing."""

import re

# With streaming synthesis, playback starts ~1s into each generate call, so
# larger chunks amortize the per-call fixed cost (prompt prefill). Kept
# moderate rather than maximal: this also caps synth-batch coalescing, and a
# batch is the granularity of the block position (read-mode highlight) and
# of /seek responsiveness.
MAX_CHUNK_CHARS = 300
FIRST_CHUNK_CHARS = 200

_SENTENCE_BREAK = re.compile(r"(?<=[.!?;:])\s+")

# English speech runs ~12-14 chars/sec; this seeds the per-channel estimate
# that block_span uses until a finished batch recalibrates it.
CHARS_PER_SEC = 12 / 0.9


def sanitize_markdown(text):
    """Strip markdown down to speakable prose. Code blocks are dropped
    entirely."""
    text = re.sub(r"```.*?(```|\Z)", " ", text, flags=re.S)
    text = re.sub(r"~~~.*?(~~~|\Z)", " ", text, flags=re.S)
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)  # images
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)  # links -> text
    text = re.sub(r"`([^`]*)`", r"\1", text)  # inline code -> bare text
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.M)  # headers
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.M)  # bullets
    text = re.sub(r"^\s*\d+\.\s+", "", text, flags=re.M)  # numbered lists
    text = re.sub(r"^\s*>\s?", "", text, flags=re.M)  # blockquotes
    # hr / table separator rows
    text = re.sub(r"^[|+\-=:\s]+$", "", text, flags=re.M)
    text = re.sub(r"\*{1,3}|_{2,3}", "", text)  # bold/italic markers
    # emoji and dingbat/symbol/arrow blocks the model would try to vocalize
    text = re.sub(
        "[\U0001F000-\U0001FBFF\u2600-\u27BF\u2190-\u21FF\u2B00-\u2BFF"
        "\uFE0F]",
        "", text)
    text = text.replace("|", ", ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\s*\n\s*", "\n", text)
    return text.strip()


def block_span(layout, sec0, sec1, chars_per_sec=CHARS_PER_SEC):
    """Block-index range estimated audible between sec0..sec1 of a synth
    batch's audio. layout is [(block_idx, char_count), ...] in speech order;
    position is interpolated by character share at chars_per_sec."""
    c0 = sec0 * chars_per_sec
    c1 = sec1 * chars_per_sec
    sel = []
    pos = 0.0
    for idx, chars in layout:
        start, end = pos, pos + chars
        pos = end + 1  # joining space
        if end <= c0:
            continue
        if start >= c1:
            break
        sel.append(idx)
    if not sel:  # audio ran past the estimate (slow speech); stay on the tail
        sel = [layout[-1][0]]
    return (sel[0], sel[-1])


def _cut(sentence, limit):
    cut = sentence.rfind(" ", 0, limit)
    if cut <= 0:
        cut = limit
    return sentence[:cut].strip(), sentence[cut:].strip()


def chunk_text(text, max_chars=MAX_CHUNK_CHARS, first_chars=FIRST_CHUNK_CHARS):
    """Greedily group sentences into chunks, per line.

    The size limit ramps up (first_chars, doubling to max_chars) so the
    first chunk synthesizes fast and playback starts early.
    """
    chunks = []
    buf = ""
    limit = min(first_chars, max_chars)

    def emit():
        nonlocal buf, limit
        chunks.append(buf)
        buf = ""
        limit = min(limit * 2, max_chars)

    for line in filter(None, (ln.strip() for ln in text.split("\n"))):
        for sentence in _SENTENCE_BREAK.split(line):
            while sentence:
                room = limit - (len(buf) + 1 if buf else 0)
                if len(sentence) <= room:
                    buf = f"{buf} {sentence}" if buf else sentence
                    sentence = ""
                elif buf:
                    emit()
                else:
                    buf, sentence = _cut(sentence, limit)
                    emit()
        if buf:
            emit()
    return chunks
