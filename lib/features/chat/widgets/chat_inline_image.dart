import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

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
            child: CachedNetworkImage(
              imageUrl: imageUrl,
              fit: BoxFit.cover,
              httpHeaders: headers,
              errorWidget: (_, __, ___) => Container(
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
