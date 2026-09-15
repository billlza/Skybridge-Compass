"""Strict source extraction and bounded replacement for shared weather shaders."""
from pathlib import Path


def read_agsl(path: Path) -> str:
    text = path.read_text()
    begin, end = 'val SOURCE = """', '""".trimIndent()'
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError(f'{path}: expected one shader source literal')
    source = text.split(begin, 1)[1].split(end, 1)[0].strip()
    if '"' in source or not source.isascii():
        raise ValueError(f'{path}: shader must be ASCII with no string literals')
    return source


def replace_field(text: str, name: str, source: str) -> str:
    begin, end = f'// BEGIN {name}\n', f'// END {name}'
    if text.count(begin) != 1 or text.count(end) != 1:
        raise ValueError(f'Expected exactly one {name} field')
    start = text.index(begin) + len(begin)
    finish = text.index(end, start)
    hlsl = source.replace('fract(', 'frac(').replace('mix(', 'lerp(')
    # Unit view/light vectors make this phase denominator positive. FXC cannot prove
    # the bound and warns on pow; abs preserves its value while stating that domain.
    hlsl = hlsl.replace(
        'pow(1.0 + g * g - 2.0 * g * alignment, 1.5)',
        'pow(abs(1.0 + g * g - 2.0 * g * alignment), 1.5)')
    return text[:start] + hlsl + '\n' + text[finish:]


def write_outputs(outputs: dict[Path, str], check: bool) -> None:
    for path, text in outputs.items():
        if check:
            if path.read_text() != text:
                raise ValueError(f'{path} differs from the shared shader')
        else:
            path.write_text(text)
        print(f'{path.name}: ' + ('exact match' if check else 'exported'))
