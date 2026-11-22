import 'package:flutter/material.dart';

// ============================================================================
// Reusable Terminal Console Log Panel (Shared by MergePage & TrimPage)
// ============================================================================

class ConsoleLogPanel extends StatelessWidget {
  final String title;
  final String commandPreview;
  final String idleMessage;
  final List<String> logs;
  final ScrollController scrollController;
  final String? statusText;
  final double? progress;
  final EdgeInsetsGeometry? margin;

  const ConsoleLogPanel({
    super.key,
    required this.title,
    required this.commandPreview,
    required this.idleMessage,
    required this.logs,
    required this.scrollController,
    this.statusText,
    this.progress,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 125,
      margin: margin,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.grey[800]! : Colors.grey[400]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const Spacer(),
              if (statusText != null)
                Text(
                  statusText!,
                  style: TextStyle(
                    color: colorScheme.primary,
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: progress, minHeight: 3),
          ],
          Divider(color: Colors.grey[800], height: 10),
          if (commandPreview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                "\$ $commandPreview",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      idleMessage,
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: scrollController,
                    itemCount: logs.length,
                    itemBuilder: (context, idx) => Text(
                      logs[idx],
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
