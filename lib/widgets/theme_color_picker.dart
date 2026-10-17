import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../state/app_state.dart';

/// Opens the appearance color picker: quick preset swatches plus a custom
/// HSV picker. The chosen seed color is persisted through [state].
Future<void> showThemeColorPicker(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ThemeColorDialog(initial: Color(state.themeColor)),
  );
}

class _ThemeColorDialog extends StatefulWidget {
  const _ThemeColorDialog({required this.initial});

  final Color initial;

  @override
  State<_ThemeColorDialog> createState() => _ThemeColorDialogState();
}

class _ThemeColorDialogState extends State<_ThemeColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  /// The wallpaper's own colours, offered as swatches. Empty on devices that
  /// will not report them, in which case the row is simply not shown.
  List<int> _wallpaper = <int>[];

  Color get _color => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final colors = await context.read<AppState>().refreshWallpaperColor();
      if (!mounted) return;
      setState(() => _wallpaper = colors);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final s = context.strings;
    return AlertDialog(
      title: Text(s.t('主题色')),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Label(s.t('预设')),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final value in kThemeColorPresets)
                    _Swatch(
                      color: Color(value),
                      selected: _color.toARGB32() == value,
                      onTap: () => setState(
                        () => _hsv = HSVColor.fromColor(Color(value)),
                      ),
                    ),
                ],
              ),
              if (_wallpaper.isNotEmpty) ...[
                const SizedBox(height: 20),
                _Label(s.t('壁纸')),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final value in _wallpaper)
                      _Swatch(
                        color: Color(value),
                        selected: _color.toARGB32() == value,
                        onTap: () => setState(
                          () => _hsv = HSVColor.fromColor(Color(value)),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              _Label(s.t('自定义')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _color,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.black12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '#${_color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              _ChannelSlider(
                label: s.t('色相'),
                value: _hsv.hue,
                max: 360,
                colors: const [
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ],
                onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
              ),
              _ChannelSlider(
                label: s.t('饱和度'),
                value: _hsv.saturation,
                max: 1,
                colors: [
                  HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
                  HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor(),
                ],
                onChanged: (v) => setState(() => _hsv = _hsv.withSaturation(v)),
              ),
              _ChannelSlider(
                label: s.t('明度'),
                value: _hsv.value,
                max: 1,
                colors: [
                  HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 0).toColor(),
                  HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
                ],
                onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('取消')),
        ),
        FilledButton(
          onPressed: () async {
            await state.setThemeColor(_color.toARGB32());
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(s.t('确定')),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.black12,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 20, color: Colors.white)
            : null,
      ),
    );
  }
}

class _ChannelSlider extends StatelessWidget {
  const _ChannelSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.colors,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double max;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: LinearGradient(colors: colors),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6,
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  disabledActiveTrackColor: Colors.transparent,
                  disabledInactiveTrackColor: Colors.transparent,
                ),
                child: Slider(
                  value: value.clamp(0.0, max).toDouble(),
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
