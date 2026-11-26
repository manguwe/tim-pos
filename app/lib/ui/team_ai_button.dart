import 'package:flutter/material.dart';

import 'theme.dart';

/// A small floating button for Team AI that sits over every screen, including the till. Drag it out of the way if it covers something.
class TeamAiButton extends StatefulWidget {
  const TeamAiButton({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  State<TeamAiButton> createState() => _TeamAiButtonState();
}

class _TeamAiButtonState extends State<TeamAiButton> {
  // Distance from the right and bottom edges. Starts above the bottom bar, on the right.
  double _right = 12;
  double _bottom = 96;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Positioned(
      right: _right,
      bottom: _bottom,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _right = (_right - d.delta.dx).clamp(4.0, size.width - 110);
          _bottom = (_bottom - d.delta.dy).clamp(4.0, size.height - 120);
        }),
        child: Material(
          color: Brand.teal,
          elevation: 6,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: widget.onTap,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome, color: Colors.white, size: 18),
                SizedBox(width: 6),
                Text('Team AI', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
