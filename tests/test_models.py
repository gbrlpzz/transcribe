from transcribe.engine import DEFAULT_MODEL, MODELS


def test_release_default_is_quantized_turbo():
    assert DEFAULT_MODEL == "turbo-q4"
    assert MODELS["turbo-q4"]["mlx"] == "mlx-community/whisper-large-v3-turbo-4bit"


def test_legacy_turbo_alias_still_resolves_to_fp16():
    assert MODELS["turbo"]["mlx"] == "mlx-community/whisper-turbo"


def test_faster_backend_shares_one_turbo_repo():
    repos = {info["faster"] for info in MODELS.values()}
    assert repos == {"Systran/faster-whisper-turbo"}


def test_release_version():
    import transcribe

    assert transcribe.__version__ == "0.4.0"
