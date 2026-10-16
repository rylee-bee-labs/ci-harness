from text import shout


def test_shout() -> None:
    assert shout("a") == "A"
