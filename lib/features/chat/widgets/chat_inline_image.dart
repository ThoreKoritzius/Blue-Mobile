import 'package:flutter/material.dart';

import '../../../core/widgets/protected_network_image.dart';

class ChatInlineImage extends StatelessWidget {
  const ChatInlineImage({
    super.key,
    required this.imageUrl,
    required this.headers,
    required this.onTap,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ProtectedNetworkImage(
                imageUrl: imageUrl,
                headers: headers,
                fit: BoxFit.cover,
                errorWidget: Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined, size: 28),
                  ),
                ),
              ),
          ),
        ),
      ),
    );
  }
}
