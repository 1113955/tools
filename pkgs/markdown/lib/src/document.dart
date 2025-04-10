// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'ast.dart';
import 'block_parser.dart';
import 'block_syntaxes/block_syntax.dart';
import 'extension_set.dart';
import 'inline_parser.dart';
import 'inline_syntaxes/inline_syntax.dart';
import 'line.dart';
import 'util.dart';

/// Maintains the context needed to parse a Markdown document.
class Document {
  final Map<String, LinkReference> linkReferences = {};

  /// Footnote ref count, keys are case-sensitive and added by define syntax.
  final footnoteReferences = <String, int>{};

  /// Footnote labels by appearing order.
  ///
  /// They are case-insensitive and added by ref syntax.
  final footnoteLabels = <String>[];
  final Resolver? linkResolver;
  final Resolver? imageLinkResolver;
  final bool encodeHtml;

  /// Whether to use default block syntaxes.
  final bool withDefaultBlockSyntaxes;

  /// Whether to use default inline syntaxes.
  ///
  /// Need to set both [withDefaultInlineSyntaxes] and [encodeHtml] to
  /// `false` to disable all inline syntaxes including html encoding syntaxes.
  final bool withDefaultInlineSyntaxes;

  final _blockSyntaxes = <BlockSyntax>{};
  final _inlineSyntaxes = <InlineSyntax>{};
  final bool hasCustomInlineSyntaxes;

  Iterable<BlockSyntax> get blockSyntaxes => _blockSyntaxes;

  Iterable<InlineSyntax> get inlineSyntaxes => _inlineSyntaxes;

  Document({
    Iterable<BlockSyntax>? blockSyntaxes,
    Iterable<InlineSyntax>? inlineSyntaxes,
    ExtensionSet? extensionSet,
    this.linkResolver,
    this.imageLinkResolver,
    this.encodeHtml = true,
    this.withDefaultBlockSyntaxes = true,
    this.withDefaultInlineSyntaxes = true,
  }) : hasCustomInlineSyntaxes = (inlineSyntaxes?.isNotEmpty ?? false) ||
            (extensionSet?.inlineSyntaxes.isNotEmpty ?? false) {
    if (blockSyntaxes != null) {
      _blockSyntaxes.addAll(blockSyntaxes);
    }
    if (inlineSyntaxes != null) {
      _inlineSyntaxes.addAll(inlineSyntaxes);
    }

    if (extensionSet == null) {
      if (withDefaultBlockSyntaxes) {
        _blockSyntaxes.addAll(ExtensionSet.commonMark.blockSyntaxes);
      }

      if (withDefaultInlineSyntaxes) {
        _inlineSyntaxes.addAll(ExtensionSet.commonMark.inlineSyntaxes);
      }
    } else {
      _blockSyntaxes.addAll(extensionSet.blockSyntaxes);
      _inlineSyntaxes.addAll(extensionSet.inlineSyntaxes);
    }
  }

  /// Parses the given [lines] of Markdown to a series of AST nodes.
  List<Node> parseLines(List<String> lines) =>
      parseLineList(lines.map(Line.new).toList());

  /// Parses the given [text] to a series of AST nodes.
  List<Node> parse(String text) => parseLineList(text.toLines());

  /// Parses the given [lines] of [Line] to a series of AST nodes.
  List<Node> parseLineList(List<Line> lines) {
    if (lines.isNotEmpty) {
      final lastLine = lines.last;
      final emptyListPattern =
          RegExp(r'^[ ]{0,3}(?:(\d{1,9})[\.)]|[*+-])[ \t]*$');
      if (emptyListPattern.hasMatch(lastLine.content)) {
        // If the last line is a blank line, remove it.
        lines.removeLast();
      }

      // if inline syntax is started, but not ended, remove it.
      final start = isInlineSyntaxStarted(lastLine.content);
      if (start > 0 && !isInlineSyntaxEnded(lastLine.content)) {
        final content = lastLine.content.substring(0, start - 1);
        lines.removeLast();
        if (content.isNotEmpty) {
          // If the last line is not empty, add it back.
          lines.add(Line(content));
        }
      }
    }

    final nodes = BlockParser(lines, this).parseLines();
    _parseInlineContent(nodes);
    // Do filter after parsing inline as we need ref count.
    return _filterFootnotes(nodes);
  }

  /// Parses the given inline Markdown [text] to a series of AST nodes.
  List<Node> parseInline(String text) => InlineParser(text, this).parse();

  void _parseInlineContent(List<Node> nodes) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is UnparsedContent) {
        final inlineNodes = parseInline(node.textContent);
        nodes.removeAt(i);
        nodes.insertAll(i, inlineNodes);
        i += inlineNodes.length - 1;
      } else if (node is Element && node.children != null) {
        _parseInlineContent(node.children!);
      }
    }
  }

  /// Footnotes could be defined in arbitrary positions of a document, we need
  /// to distinguish them and put them behind; and every footnote definition
  /// may have multiple backrefs, we need to append backrefs for it.
  List<Node> _filterFootnotes(List<Node> nodes) {
    final footnotes = <Element>[];
    final blocks = <Node>[];
    for (final node in nodes) {
      if (node is Element &&
          node.tag == 'li' &&
          footnoteReferences.containsKey(node.footnoteLabel)) {
        final label = node.footnoteLabel;
        var count = 0;
        if (label != null && (count = footnoteReferences[label] ?? 0) > 0) {
          footnotes.add(node);
          final children = node.children;
          if (children != null) {
            _appendBackref(children, Uri.encodeComponent(label), count);
          }
        }
      } else {
        blocks.add(node);
      }
    }

    if (footnotes.isNotEmpty) {
      // Sort footnotes by appearing order.
      final ordinal = {
        for (var i = 0; i < footnoteLabels.length; i++)
          'fn-${footnoteLabels[i]}': i,
      };
      footnotes.sort((l, r) {
        final idl = l.attributes['id']?.toLowerCase() ?? '';
        final idr = r.attributes['id']?.toLowerCase() ?? '';
        return (ordinal[idl] ?? 0) - (ordinal[idr] ?? 0);
      });
      final list = Element('ol', footnotes);

      // Ignore GFM attribute: <data-footnotes>.
      final section = Element('section', [list])
        ..attributes['class'] = 'footnotes';
      blocks.add(section);
    }
    return blocks;
  }

  /// Generate backref nodes, append them to footnote definition's last child.
  void _appendBackref(List<Node> children, String ref, int count) {
    final refs = [
      for (var i = 0; i < count; i++) ...[
        Text(' '),
        _ElementExt.footnoteAnchor(ref, i)
      ]
    ];
    if (children.isEmpty) {
      children.addAll(refs);
    } else {
      final last = children.last;
      if (last is Element) {
        last.children?.addAll(refs);
      } else {
        children.last = Element('p', [last, ...refs]);
      }
    }
  }

  int isInlineSyntaxStarted(String content) {
    /// 모든 인라인 문법 시작 패턴을 결합한 정규표현식
    final anyInlineMarkdownStart = RegExp(r'(\*\*|__)(?!\s)|' // bold
        r'(?<!\*|\w)(\*|_)(?!\*|_|\s)|' // italic
        r'(\*\*\*|___)(?!\s)|' // bold italic
        r'~~(?!\s)|' // strikethrough
        '`(?!`)|' // inline code
        r'\[|' // link
        r'!\[' // image
        );
    final match = anyInlineMarkdownStart.allMatches(content).last;
    return match.end;
  }

  bool isInlineSyntaxEnded(String content) {
    // 인라인 문법의 닫는 패턴을 확인하기 위한 스택 기반 처리
    final stack = <String>[];
    var isEscaped = false;

    for (var i = 0; i < content.length; i++) {
      final char = content[i];

      // 이스케이프 문자 처리
      if (char == r'\' && !isEscaped) {
        isEscaped = true;
        continue;
      }

      if (isEscaped) {
        isEscaped = false;
        continue;
      }

      // 코드 블록 처리
      if (i + 2 < content.length && content.substring(i, i + 3) == '```') {
        if (stack.isNotEmpty && stack.last == '```') {
          stack.removeLast();
        } else {
          stack.add('```');
        }
        i += 2;
        continue;
      }

      // 볼드 이탤릭 처리
      if (i + 2 < content.length &&
          (content.substring(i, i + 3) == '***' ||
              content.substring(i, i + 3) == '___')) {
        final pattern = content.substring(i, i + 3);
        if (stack.isNotEmpty && stack.last == pattern) {
          stack.removeLast();
        } else {
          stack.add(pattern);
        }
        i += 2;
        continue;
      }

      // 볼드 처리
      if (i + 1 < content.length &&
          (content.substring(i, i + 2) == '**' ||
              content.substring(i, i + 2) == '__')) {
        final pattern = content.substring(i, i + 2);
        if (stack.isNotEmpty && stack.last == pattern) {
          stack.removeLast();
        } else {
          stack.add(pattern);
        }
        i += 1;
        continue;
      }

      // 취소선 처리
      if (i + 1 < content.length && content.substring(i, i + 2) == '~~') {
        if (stack.isNotEmpty && stack.last == '~~') {
          stack.removeLast();
        } else {
          stack.add('~~');
        }
        i += 1;
        continue;
      }

      // 인라인 코드 처리
      if (char == '`' && (i == 0 || content[i - 1] != '`')) {
        if (stack.isNotEmpty && stack.last == '`') {
          stack.removeLast();
        } else {
          stack.add('`');
        }
        continue;
      }

      // 이탤릭 처리
      if ((char == '*' || char == '_') &&
          (i == 0 || (content[i - 1] != char && content[i - 1] != r'\')) &&
          (i + 1 >= content.length || content[i + 1] != char)) {
        if (stack.isNotEmpty && stack.last == char) {
          stack.removeLast();
        } else {
          stack.add(char);
        }
        continue;
      }

      // 링크와 이미지 처리
      if (char == '[' && (i == 0 || content[i - 1] != '!')) {
        stack.add('[');
        continue;
      }

      if (char == '!' && i + 1 < content.length && content[i + 1] == '[') {
        stack.add('![');
        i += 1;
        continue;
      }

      if (char == ']' && i + 1 < content.length && content[i + 1] == '(') {
        if (stack.isNotEmpty && (stack.last == '[' || stack.last == '![')) {
          final openTag = stack.removeLast();
          stack.add('$openTag](');
        }
        i += 1;
        continue;
      }

      if (char == ')') {
        if (stack.isNotEmpty && (stack.last.endsWith(']('))) {
          stack.removeLast();
        }
        continue;
      }
    }

    // 스택이 비어있으면 모든 인라인 문법이 올바르게 종료된 것
    return stack.isEmpty;
  }
}

extension _ElementExt on Element {
  static Element footnoteAnchor(String ref, int i) {
    final num = '${i + 1}';
    final suffix = i > 0 ? '-$num' : '';
    final e = Element.empty('tag');
    e.match;
    return Element('a', [
      Text('\u21a9'),
      if (i > 0)
        Element('sup', [Text(num)])..attributes['class'] = 'footnote-ref',
    ])
      // Ignore GFM's attributes:
      // <data-footnote-backref aria-label="Back to content">.
      ..attributes['href'] = '#fnref-$ref$suffix'
      ..attributes['class'] = 'footnote-backref';
  }

  String get match => tag;
}

/// A [link reference
/// definition](https://spec.commonmark.org/0.30/#link-reference-definitions).
class LinkReference {
  /// The [link label](https://spec.commonmark.org/0.30/#link-label).
  ///
  /// Temporarily, this class is also being used to represent the link data for
  /// an inline link (the destination and title), but this should change before
  /// the package is released.
  final String label;

  /// The [link destination](https://spec.commonmark.org/0.30/#link-destination).
  final String destination;

  /// The [link title](https://spec.commonmark.org/0.30/#link-title).
  final String? title;

  /// Construct a new [LinkReference], with all necessary fields.
  ///
  /// If the parsed link reference definition does not include a title, use
  /// `null` for the [title] parameter.
  LinkReference(this.label, this.destination, this.title);
}
