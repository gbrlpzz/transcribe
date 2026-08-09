from transcribe.smarttext import apply_smart_text, strip_whitespace


def test_punctuation():
    assert apply_smart_text("hello comma how are you period") == "hello, how are you."
    assert apply_smart_text("really question mark") == "really?"
    assert apply_smart_text("wow exclamation mark") == "wow!"


def test_structure():
    assert apply_smart_text("first line new line second") == "first line\nsecond"
    assert apply_smart_text("a new paragraph b") == "a\n\nb"


def test_embedded_words_not_touched():
    # tokens embedded in real words must survive
    assert apply_smart_text("periodic periods hyphens") == "periodic periods hyphens"


def test_delete_that():
    assert apply_smart_text("remove this word delete that") == "remove this"
    assert apply_smart_text("delete that") == ""


def test_quotes_and_symbols():
    assert apply_smart_text("open quote hi close quote") == "\u201chi\u201d"
    assert apply_smart_text("email me at sign example") == "email me @ example"


def test_strip_whitespace():
    assert strip_whitespace("  hello   world  ") == "hello world"
