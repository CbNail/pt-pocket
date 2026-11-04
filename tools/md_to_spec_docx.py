"""把 docs/需求规格书.md 生成为同口径的 docs/需求规格书.docx。

用途：仓库硬性规则要求需求规格书的 md 与 Word 两个版本保持一致（README §0 第 2 条）。
转换口径与既有 docx 一致：`#` → Heading 1、`##` → Heading 2、`###` → Heading 3、
`####` → Heading 4、无序列表 → List Bullet、有序列表 → List Number、引用 → Intense Quote、
围栏代码 → Code、markdown 表格 → Word 表格（Table Grid），行内 `**粗体**` 与 `` `代码` `` 保留语义。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import docx
from docx.enum.style import WD_STYLE_TYPE
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor

MD_PATH = Path('docs/需求规格书.md')
DOCX_PATH = Path('docs/需求规格书.docx')


def _style_setup(document: docx.Document) -> None:
    """统一正文字体（含中日韩字形），保证中文不会回退成方框。"""
    normal = document.styles['Normal']
    normal.font.name = 'Calibri'
    normal.font.size = Pt(10.5)
    normal.element.rPr.rFonts.set(qn('w:eastAsia'), '微软雅黑')
    for style_name in ('Heading 1', 'Heading 2', 'Heading 3', 'Heading 4', 'Body Text', 'Intense Quote'):
        try:
            style = document.styles[style_name]
        except KeyError:
            continue
        style.font.name = 'Calibri'
        if style.element.rPr is not None:
            style.element.rPr.rFonts.set(qn('w:eastAsia'), '微软雅黑')
    try:
        code = document.styles['Code']
    except KeyError:
        code = document.styles.add_style('Code', WD_STYLE_TYPE.PARAGRAPH)
        code.base_style = document.styles['Normal']
    code.font.name = 'Consolas'
    code.font.size = Pt(9)
    code.element.rPr.rFonts.set(qn('w:eastAsia'), 'Consolas')


_INLINE = re.compile(r'(\*\*[^*]+\*\*|`[^`]+`)')


def _add_runs(paragraph, text: str) -> None:
    """写入行内格式：`**粗体**` 与 `` `等宽` ``。"""
    for piece in _INLINE.split(text):
        if not piece:
            continue
        if piece.startswith('**') and piece.endswith('**') and len(piece) > 4:
            run = paragraph.add_run(piece[2:-2])
            run.bold = True
        elif piece.startswith('`') and piece.endswith('`') and len(piece) > 2:
            run = paragraph.add_run(piece[1:-1])
            run.font.name = 'Consolas'
            run.font.size = Pt(9)
            run.font.color.rgb = RGBColor(0x1F, 0x3B, 0x57)
        else:
            paragraph.add_run(piece)


def _split_table_row(line: str) -> list[str]:
    cells = line.strip().strip('|').split('|')
    return [cell.strip() for cell in cells]


def _is_table_divider(line: str) -> bool:
    return bool(re.fullmatch(r'\|[\s:|-]+\|', line.strip()))


def convert(md_text: str, document: docx.Document) -> None:
    lines = md_text.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        # 围栏代码块
        if stripped.startswith('```'):
            index += 1
            buffer: list[str] = []
            while index < len(lines) and not lines[index].strip().startswith('```'):
                buffer.append(lines[index])
                index += 1
            index += 1
            for code_line in buffer:
                document.add_paragraph(code_line, style='Code')
            continue

        # 表格
        if stripped.startswith('|') and index + 1 < len(lines) and _is_table_divider(lines[index + 1]):
            header = _split_table_row(line)
            index += 2
            rows: list[list[str]] = []
            while index < len(lines) and lines[index].strip().startswith('|'):
                rows.append(_split_table_row(lines[index]))
                index += 1
            table = document.add_table(rows=1, cols=len(header))
            table.style = 'Table Grid'
            for cell_index, text in enumerate(header):
                paragraph = table.rows[0].cells[cell_index].paragraphs[0]
                run = paragraph.add_run(text)
                run.bold = True
            for row in rows:
                cells = table.add_row().cells
                for cell_index, text in enumerate(row[: len(header)]):
                    _add_runs(cells[cell_index].paragraphs[0], text)
            document.add_paragraph('')
            continue

        # 标题
        if stripped.startswith('#'):
            level = len(stripped) - len(stripped.lstrip('#'))
            text = stripped[level:].strip()
            style = {1: 'Heading 1', 2: 'Heading 2', 3: 'Heading 3'}.get(level, 'Heading 4')
            _add_runs(document.add_paragraph(style=style), text)
            index += 1
            continue

        # 引用（连续多行合并为一个 Intense Quote）
        if stripped.startswith('>'):
            buffer = []
            while index < len(lines) and lines[index].strip().startswith('>'):
                content = lines[index].strip().lstrip('>').strip()
                if content:
                    buffer.append(content)
                index += 1
            _add_runs(document.add_paragraph(style='Intense Quote'), ' '.join(buffer))
            continue

        # 无序列表（含两层缩进）
        if re.match(r'^\s*[-*]\s+', line):
            indent = len(line) - len(line.lstrip(' '))
            text = re.sub(r'^\s*[-*]\s+', '', line)
            paragraph = document.add_paragraph(style='List Bullet')
            if indent >= 2:
                paragraph.paragraph_format.left_indent = Pt(36 if indent >= 4 else 18)
            _add_runs(paragraph, text)
            index += 1
            continue

        # 有序列表
        if re.match(r'^\s*\d+[.)]\s+', line):
            text = re.sub(r'^\s*\d+[.)]\s+', '', line)
            _add_runs(document.add_paragraph(style='List Number'), text)
            index += 1
            continue

        # 分隔线
        if re.fullmatch(r'-{3,}', stripped):
            index += 1
            continue

        # 空行
        if not stripped:
            index += 1
            continue

        # 普通段落（行尾两个空格视为换行，这里合并为一行）
        _add_runs(document.add_paragraph(style='Body Text'), stripped.rstrip())
        index += 1


def main() -> int:
    md_text = MD_PATH.read_text(encoding='utf-8')
    document = docx.Document()
    _style_setup(document)
    # 标题
    title = md_text.splitlines()[0].lstrip('#').strip()
    heading = document.add_paragraph(style='Heading 1')
    heading.alignment = WD_ALIGN_PARAGRAPH.LEFT
    heading.add_run(title)
    convert('\n'.join(md_text.splitlines()[1:]), document)
    document.save(str(DOCX_PATH))
    print(f'已生成 {DOCX_PATH}：段落 {len(document.paragraphs)} 个，表格 {len(document.tables)} 个')
    return 0


if __name__ == '__main__':
    sys.exit(main())