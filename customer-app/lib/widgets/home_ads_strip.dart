import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_content.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import '../l10n/strings.dart';

/// Home-screen ads (managed from the Agent App): the WHOLE picture is shown in its own proportions
/// (nothing is cut off: the banner is as tall as its picture needs), several ads slide by themselves every 5
/// seconds (a swipe also works and restarts the wait) with dots under them. An ad with a link opens it in the
/// browser when tapped. An ad without a picture shows its title and text on the purple card.
class HomeAdsStrip extends StatefulWidget {
  const HomeAdsStrip({super.key, required this.ads, this.slideEvery = const Duration(seconds: 5)});

  final List<HomeAd> ads;
  final Duration slideEvery;

  @override
  State<HomeAdsStrip> createState() => _HomeAdsStripState();
}

class _HomeAdsStripState extends State<HomeAdsStrip> {
  static const double _defaultRatio = 2.6; // width / height of a text-only ad, and until a picture is measured
  static const double _minRatio = 1.4;
  static const double _maxRatio = 4.8;

  final PageController _controller = PageController();
  final Map<String, double> _ratios = {};
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _measure();
    _restartTimer();
  }

  @override
  void didUpdateWidget(HomeAdsStrip old) {
    super.didUpdateWidget(old);
    _measure();
    if (_page >= widget.ads.length) _page = 0;
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// The real proportions of every picture, so the banner is exactly as tall as it needs to be.
  void _measure() {
    for (final ad in widget.ads) {
      final bytes = ad.image;
      if (bytes == null || _ratios.containsKey(ad.id)) continue;
      _ratios[ad.id] = _defaultRatio;
      _measureOne(ad.id, bytes);
    }
  }

  Future<void> _measureOne(String id, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width, h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted || h == 0) return;
      setState(() => _ratios[id] = (w / h).clamp(_minRatio, _maxRatio));
    } catch (_) {
      // A picture that cannot be read keeps the default proportions (the card then shows nothing broken).
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.ads.length < 2) return;
    _timer = Timer.periodic(widget.slideEvery, (_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.animateToPage((_page + 1) % widget.ads.length, duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
    });
  }

  Future<void> _open(BuildContext context, HomeAd ad) async {
    final uri = Uri.tryParse(ad.linkUrl ?? '');
    if (uri == null || !uri.hasScheme) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.couldNotOpenLink)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ads = widget.ads;
    final page = _page.clamp(0, ads.length - 1);
    final width = MediaQuery.of(context).size.width - 32;
    final height = width / (_ratios[ads[page].id] ?? _defaultRatio);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          height: height,
          child: PageView.builder(
            controller: _controller,
            itemCount: ads.length,
            onPageChanged: (i) {
              setState(() => _page = i);
              _restartTimer();
            },
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _AdCard(ad: ads[i], onTap: ads[i].linkUrl == null ? null : () => _open(context, ads[i])),
            ),
          ),
        ),
        if (ads.length > 1) ...[
          const SizedBox(height: 8),
          Row(
            key: const Key('home-ad-dots'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < ads.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == page ? 18 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: i == page ? Colors.white : Colors.white.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AdCard extends StatelessWidget {
  const _AdCard({required this.ad, required this.onTap});

  final HomeAd ad;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = ad.image != null || (ad.imageUrl ?? '').isNotEmpty;
    return Material(
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: const BoxDecoration(gradient: AppColors.cardGradient),
          child: hasImage
              // The picture carries its own text and logos: all of it is shown, never cropped (fit: contain in a card of the same
              // proportions), without anything drawn over it. The title stays for screen readers.
              ? Semantics(
                  label: ad.title,
                  image: true,
                  child: ad.image != null
                      ? Image.memory(
                          ad.image!,
                          key: Key('home-ad-image-${ad.id}'),
                          fit: BoxFit.contain,
                          width: double.infinity,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        )
                      : Image.network(
                          ad.imageUrl!,
                          key: Key('home-ad-image-${ad.id}'),
                          fit: BoxFit.contain,
                          width: double.infinity,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                )
              : Padding(
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
                          AppStrings.learnMore,
                          style: AppTextStyles.body.copyWith(color: AppColors.lightGold, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
