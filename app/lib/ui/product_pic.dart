import 'dart:io';

import 'package:flutter/material.dart';

import '../photos/photo_store.dart';
import 'theme.dart';

/// A product's picture. With no picture yet, a coloured tile with the first letters of its name.
class ProductPic extends StatelessWidget {
  const ProductPic({super.key, required this.name, this.imageRef, this.size = 56, this.radius = 12});
  final String name;
  final String? imageRef;
  final double size;
  final double radius;

  static const _colours = [Brand.teal, Brand.navy, Brand.orange, Brand.green, Brand.coral, Color(0xFF6C5CE7), Color(0xFF0984E3)];

  static String initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.substring(0, words.first.length >= 2 ? 2 : 1).toUpperCase();
    return (words[0].substring(0, 1) + words[1].substring(0, 1)).toUpperCase();
  }

  Widget _fallback() {
    final c = _colours[name.hashCode.abs() % _colours.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(radius)),
      child: Text(initials(name), style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: size * 0.34)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (imageRef == null || imageRef!.isEmpty) return _fallback();
    return FutureBuilder<File?>(
      future: PhotoStore.instance.file(imageRef),
      builder: (context, snap) {
        final f = snap.data;
        if (f == null) return _fallback();
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.file(f, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).round(), errorBuilder: (_, __, ___) => _fallback()),
        );
      },
    );
  }
}
