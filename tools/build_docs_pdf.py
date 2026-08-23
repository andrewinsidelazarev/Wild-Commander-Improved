#!/usr/bin/env python3
"""Собирает единое русское руководство Wild Commander и печатает его в PDF."""

from __future__ import annotations

import html
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

import markdown
from markdown.extensions.toc import TocExtension


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
OUTPUT = DOCS / "Wild_Commander_Improved_Programmer_Guide.pdf"
STYLE = DOCS / "pdf-style.css"

DOCUMENTS = (
    ("README.md", "doc-index"),
    ("01-panel-manager.md", "doc-panel-manager"),
    ("02-plugins-and-public-api.md", "doc-plugins-api"),
    ("03-drivers.md", "doc-drivers"),
    ("04-dos-layer.md", "doc-dos"),
    ("05-memory-map.md", "doc-memory"),
)


def find_edge() -> Path:
    """Находит Edge, пригодный для безоконной печати HTML."""

    candidates = (
        Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
        Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate

    command = shutil.which("msedge")
    if command:
        return Path(command)
    raise FileNotFoundError("Microsoft Edge не найден")


def rewrite_document_links(source: str) -> str:
    """Превращает ссылки между Markdown-файлами в якоря единого документа."""

    anchors = {name: anchor for name, anchor in DOCUMENTS}
    pattern = re.compile(r"\((?!https?://)([^)#]+\.md)(#[^)]+)?\)")

    def replace(match: re.Match[str]) -> str:
        target = match.group(1).replace("\\", "/")
        fragment = match.group(2)
        if "/" in target or target not in anchors:
            return match.group(0)
        if fragment:
            return f"({fragment})"
        return f"(#{anchors[target]})"

    return pattern.sub(replace, source)


def read_combined_markdown() -> str:
    """Читает главы в фиксированном порядке и добавляет корневые якоря."""

    parts = ["[TOC]"]
    for filename, anchor in DOCUMENTS:
        path = DOCS / filename
        text = rewrite_document_links(path.read_text(encoding="utf-8"))
        lines = text.splitlines()
        if not lines or not lines[0].startswith("# "):
            raise ValueError(f"В {filename} отсутствует заголовок первого уровня")
        # Attr List задаёт корневой ID прямо заголовку. Отдельный нулевой
        # элемент перед H1 создавал пустую страницу при точном заполнении A4.
        lines[0] += f" {{#{anchor}}}"
        parts.append("\n".join(lines))
    return "\n\n".join(parts)


def classify_diagrams(body: str) -> str:
    """Помечает текстовые схемы и выбирает размер по самой широкой строке."""

    pattern = re.compile(
        r'<pre><code class="language-text">(.*?)</code></pre>',
        flags=re.DOTALL,
    )

    def replace(match: re.Match[str]) -> str:
        payload = match.group(1)
        plain = html.unescape(payload)
        lines = plain.expandtabs(4).splitlines() or [""]
        columns = max(len(line) for line in lines)
        rows = len(lines)
        if columns <= 82:
            width_class = "diagram-normal"
        elif columns <= 108:
            width_class = "diagram-wide"
        else:
            width_class = "diagram-xwide"
        height_class = " diagram-tall" if rows > 28 else ""
        return (
            f'<pre class="diagram {width_class}{height_class}" '
            f'data-columns="{columns}" data-rows="{rows}">'
            f'<code class="language-text">{payload}</code></pre>'
        )

    return pattern.sub(replace, body)


def make_html() -> str:
    """Преобразует Markdown в автономный печатный HTML с общей обложкой."""

    body = markdown.markdown(
        read_combined_markdown(),
        extensions=(
            "extra",
            "sane_lists",
            TocExtension(toc_depth="1-2", title="Оглавление", permalink=False),
        ),
        output_format="html5",
    )
    body = classify_diagrams(body)
    css = STYLE.read_text(encoding="utf-8")
    base_url = DOCS.resolve().as_uri() + "/"
    build_date = date.today().strftime("%d.%m.%Y")
    return f"""<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <base href="{html.escape(base_url, quote=True)}">
  <title>Wild Commander Improved — руководство программиста</title>
  <style>{css}</style>
</head>
<body>
  <section class="cover">
    <div class="cover-kicker">Wild Commander Improved v1.10i 2026-08-24</div>
    <h1>Руководство<br>программиста</h1>
    <div class="cover-subtitle">
      Полный API, панельный менеджер, плагины, драйверы,
      WildDOS/CORE32 и карта памяти
    </div>
    <div class="cover-grid">
      <span>Публичный API 0–86</span>
      <span>Все вызовы WildDOS</span>
      <span>Готовые примеры ASM</span>
      <span>Регистры, флаги, структуры</span>
    </div>
    <div class="cover-meta">
      Документация по текущим исходникам репозитория<br>
      Сборка PDF: {build_date}
    </div>
  </section>
  <main>{body}</main>
</body>
</html>
"""


def build_pdf() -> None:
    """Печатает временный HTML и проверяет сигнатуру результата."""

    edge = find_edge()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="wc-docs-pdf-") as temp_name:
        temp = Path(temp_name)
        html_path = temp / "guide.html"
        profile = temp / "edge-profile"
        html_path.write_text(make_html(), encoding="utf-8")

        command = (
            str(edge),
            "--headless",
            "--disable-gpu",
            "--disable-extensions",
            "--allow-file-access-from-files",
            "--run-all-compositor-stages-before-draw",
            "--no-pdf-header-footer",
            f"--user-data-dir={profile}",
            f"--print-to-pdf={OUTPUT.resolve()}",
            html_path.resolve().as_uri(),
        )
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
            check=False,
        )
        if completed.returncode != 0:
            message = completed.stderr.strip() or completed.stdout.strip()
            raise RuntimeError(f"Edge завершился с кодом {completed.returncode}: {message}")

    if not OUTPUT.is_file() or OUTPUT.stat().st_size < 1024:
        raise RuntimeError("PDF не создан или имеет недопустимо малый размер")
    with OUTPUT.open("rb") as stream:
        if stream.read(5) != b"%PDF-":
            raise RuntimeError("Результат не имеет сигнатуры PDF")

    print(f"Создано: {OUTPUT}")
    print(f"Размер: {OUTPUT.stat().st_size:,} байт")


if __name__ == "__main__":
    try:
        build_pdf()
    except Exception as error:
        print(f"Ошибка сборки PDF: {error}", file=sys.stderr)
        raise SystemExit(1)
