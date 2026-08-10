import 'package:flutter/material.dart';

double _clampD(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Suwak + edytowalne pole liczbowe do ustawiania kąta (kierunku ścieżek)
/// z precyzją do setnych części stopnia.
///
/// Suwak (krok 1°) służy do szybkiego, zgrubnego ustawienia kierunku.
/// Pole tekstowe obok pozwala wpisać dokładną wartość ręcznie — np.
/// przepisaną z pomiaru linii AB — bez utraty precyzji setnych stopnia.
class DegreeAngleInput extends StatefulWidget {
  const DegreeAngleInput({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 179.0,
    this.color = Colors.tealAccent,
    this.enabled = true,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final Color color;
  final bool enabled;

  @override
  State<DegreeAngleInput> createState() => _DegreeAngleInputState();
}

class _DegreeAngleInputState extends State<DegreeAngleInput> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value.toStringAsFixed(2));
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _submit(_ctrl.text);
    });
  }

  @override
  void didUpdateWidget(covariant DegreeAngleInput old) {
    super.didUpdateWidget(old);
    // Nie nadpisuj pola, jeśli użytkownik akurat w nim pisze.
    if (!_focusNode.hasFocus && old.value != widget.value) {
      _ctrl.text = widget.value.toStringAsFixed(2);
    }
  }

  void _submit(String text) {
    final parsed = double.tryParse(text.replaceAll(',', '.'));
    if (parsed == null) {
      _ctrl.text = widget.value.toStringAsFixed(2);
      return;
    }
    widget.onChanged(_clampD(parsed, widget.min, widget.max));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Slider(
            min: widget.min,
            max: widget.max,
            divisions: (widget.max - widget.min).round(),
            value: _clampD(widget.value, widget.min, widget.max),
            activeColor: widget.color,
            onChanged: widget.enabled
                ? (v) {
                    widget.onChanged(v);
                    _ctrl.text = v.toStringAsFixed(2);
                  }
                : null,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 82,
          child: TextField(
            controller: _ctrl,
            focusNode: _focusNode,
            enabled: widget.enabled,
            textAlign: TextAlign.right,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style:
                TextStyle(color: widget.color, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              isDense: true,
              suffixText: '°',
              suffixStyle: TextStyle(color: Colors.white54),
              enabledBorder:
                  UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.tealAccent)),
              disabledBorder:
                  UnderlineInputBorder(borderSide: BorderSide(color: Colors.white12)),
            ),
            onSubmitted: _submit,
          ),
        ),
      ],
    );
  }
}
