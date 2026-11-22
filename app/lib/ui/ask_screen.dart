import 'package:flutter/material.dart';

import '../ai/ai_service.dart';
import 'theme.dart';

class _Turn {
  _Turn(this.question);
  final String question;
  String? answer;
  String? error;
}

/// Ask about prices, stock and sales in plain words. Needs internet; the till never does.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key, required this.ai, required this.includeSales});
  final AiService ai;
  final bool includeSales;
  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _text = TextEditingController();
  final _turns = <_Turn>[];
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send(String q) async {
    final question = q.trim();
    if (question.isEmpty || _busy) return;
    final t = _Turn(question);
    setState(() { _turns.add(t); _busy = true; _text.clear(); });
    try {
      t.answer = await widget.ai.ask(question, includeSales: widget.includeSales);
    } on AiError catch (e) {
      t.error = e.message;
    } catch (_) {
      t.error = 'Something went wrong. Try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final examples = widget.includeSales
        ? ['How much is sugar?', 'How did we do today?', 'What must I restock?']
        : ['How much is sugar?', 'Do we have rice?'];
    return Scaffold(
      appBar: AppBar(title: const Text('Ask')),
      body: Column(children: [
        Expanded(
          child: _turns.isEmpty
              ? ListView(padding: const EdgeInsets.all(20), children: [
                  const Text('Ask about your shop in plain words.', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('It needs internet and can make mistakes, so check important numbers in the reports.'),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: [for (final e in examples) ActionChip(label: Text(e), onPressed: () => _send(e))]),
                ])
              : ListView(padding: const EdgeInsets.all(16), children: [
                  for (final t in _turns)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t.question, style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            if (t.answer == null && t.error == null) const Text('Thinking...')
                            else if (t.error != null) Text(t.error!, style: const TextStyle(color: Brand.coral))
                            else SelectableText(t.answer!),
                          ]),
                        ),
                      ),
                    ),
                ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  decoration: const InputDecoration(hintText: 'Type your question', counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _busy ? null : () => _send(_text.text), icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}
