import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_content.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// Horizontally swipeable home-screen ads (managed from the Agent App).
/// An ad with a link opens it in the browser when tapped.
class HomeAdsStrip extends StatelessWidget {
  const HomeAdsStrip({super.key, required this.ads});

  final List<HomeAd> ads;

  Future<void> _open(BuildContext context, HomeAd ad) async {
    final uri = Uri.tryParse(ad.linkUrl ?? '');
    if (uri == null || !uri.hasScheme) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the link.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 132,
      child: PageView.builder(
        controller: PageController(viewportFraction: ads.length == 1 ? 0.9 : 0.86),
        padEnds: ads.length == 1,
        itemCount: ads.length,
        itemBuilder: (context, i) {
          final ad = ads[i];
          return Padding(
            padding: EdgeInsets.only(left: i == 0 && ads.length > 1 ? 20 : 6, right: 6),
            child: Material(
              borderRadius: BorderRadius.circular(22),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: ad.linkUrl == null ? null : () => _open(context, ad),
                child: Ink(
                  decoration: const BoxDecoration(gradient: AppColors.cardGradient),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if ((ad.imageUrl ?? '').isNotEmpty)
                        Image.network(
                          ad.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      // Readability scrim behind the text.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [AppColors.purpleDark.withOpacity(0.85), AppColors.purpleDark.withOpacity(0.1)],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              ad.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.title.copyWith(color: Colors.white, fontSize: 18),
                            ),
                            if ((ad.body ?? '').isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                ad.body!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.85)),
                              ),
                            ],
                            if (ad.linkUrl != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Learn more ›',
                                style: AppTextStyles.body.copyWith(color: AppColors.lightGold, fontWeight: FontWeight.w800),
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
          );
        },
      ),
    );
  }
}
