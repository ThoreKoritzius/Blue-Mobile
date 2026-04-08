import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models/story_day_model.dart';

class ChatDayMemoryCard extends StatelessWidget {
  const ChatDayMemoryCard({
    super.key,
    required this.date,
    required this.story,
    required this.loading,
    required this.headers,
    required this.onTap,
    this.previewUrl,
    this.width = 168,
    this.height = 124,
  });

  final String date;
  final StoryDayModel? story;
  final bool loading;
  final Map<String, String> headers;
  final VoidCallback onTap;
  /// Pre-built authenticated URL for the hero image.
  final String? previewUrl;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final place = [
      story?.place.trim() ?? '',
      story?.country.trim() ?? '',
    ].where((part) => part.isNotEmpty).join(', ');

    return SizedBox(
      width: width,
      height: height,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (previewUrl != null && previewUrl!.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: previewUrl!,
                      fit: BoxFit.cover,
                      httpHeaders: headers,
                      errorWidget: (_, __, ___) => _fallback(context),
                    )
                  else
                    _fallback(context),
                  if (loading)
                    Container(color: Colors.white.withValues(alpha: 0.28)),
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x14000000),
                          Color(0x22000000),
                          Color(0xC40C1728),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          date,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        if (place.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            place,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.88),
                                  height: 1.3,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colorScheme.primaryContainer, colorScheme.surface],
        ),
      ),
    );
  }
}
