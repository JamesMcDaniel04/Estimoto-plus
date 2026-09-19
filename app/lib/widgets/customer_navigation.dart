import 'package:flutter/material.dart';
import '../state/plus_controller.dart';
import '../theme.dart';

/// Shares the staff app's inset center button and carved navigation geometry.
class CustomerNavigation extends StatelessWidget {
  const CustomerNavigation({super.key, required this.controller});
  final PlusController controller;

  @override
  Widget build(BuildContext context) => BottomAppBar(
    height: 80,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    color: Theme.of(context).colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 3,
    shadowColor: Colors.black.withValues(alpha: .18),
    shape: const CradledNavigationShape(),
    clipBehavior: Clip.antiAlias,
    notchMargin: 8,
    // The bar has a fixed height, so its labels cap their text scale.
    child: MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Row(
        children: [
          _destination(
            context,
            0,
            'Garage',
            'garage',
            Icons.directions_car_outlined,
            Icons.directions_car,
          ),
          _destination(
            context,
            1,
            'Estimates',
            'estimates',
            Icons.receipt_long_outlined,
            Icons.receipt_long,
          ),
          const SizedBox(width: 96),
          _destination(
            context,
            3,
            'Repairs',
            'repairs',
            Icons.build_outlined,
            Icons.build,
          ),
          _destination(
            context,
            4,
            'Find Help',
            'find-help',
            Icons.place_outlined,
            Icons.place,
          ),
        ],
      ),
    ),
  );

  Widget _destination(
    BuildContext context,
    int index,
    String label,
    String key,
    IconData icon,
    IconData selectedIcon,
  ) {
    final selected = controller.tab == index;
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : context.plus.muted;
    void select() => controller.selectTab(index);
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: select,
        child: Tooltip(
          message: label,
          child: InkWell(
            key: Key('nav-$key'),
            borderRadius: BorderRadius.circular(12),
            onTap: select,
            child: SizedBox(
              height: 64,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(selected ? selectedIcon : icon, size: 23, color: color),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
}

class EstibotNavigationButton extends StatelessWidget {
  const EstibotNavigationButton({
    super.key,
    required this.selected,
    required this.onPressed,
  });
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: SizedBox.square(
      dimension: 64,
      child: FloatingActionButton(
        key: const Key('nav-estibot'),
        heroTag: 'estibot_navigation',
        tooltip: 'Estibot',
        backgroundColor: selected
            ? context.plus.navyCard
            : Theme.of(context).colorScheme.primary,
        foregroundColor: selected
            ? context.plus.onNavy
            : Theme.of(context).colorScheme.onPrimary,
        elevation: 4,
        shape: CircleBorder(
          side: BorderSide(
            color: Theme.of(context).colorScheme.primaryContainer,
            width: 2,
          ),
        ),
        onPressed: onPressed,
        child: const Icon(Icons.support_agent, size: 30),
      ),
    ),
  );
}

class InsetEstibotLocation extends FloatingActionButtonLocation {
  const InsetEstibotLocation();
  @override
  Offset getOffset(ScaffoldPrelayoutGeometry geometry) =>
      FloatingActionButtonLocation.centerDocked.getOffset(geometry) +
      const Offset(0, 22);
}

class CradledNavigationShape extends NotchedShape {
  const CradledNavigationShape();
  @override
  Path getOuterPath(Rect host, Rect? guest) {
    const corner = 24.0;
    final path = Path()
      ..moveTo(host.left, host.bottom)
      ..lineTo(host.left, host.top + corner)
      ..quadraticBezierTo(host.left, host.top, host.left + corner, host.top);
    if (guest != null && host.overlaps(guest)) {
      final cx = guest.center.dx;
      final cy = guest.center.dy;
      final radius = guest.width / 2;
      const shoulder = 24.0;
      path
        ..lineTo(cx - radius - shoulder, host.top)
        ..cubicTo(
          cx - radius - 4,
          host.top,
          cx - radius,
          cy - 12,
          cx - radius,
          cy,
        )
        ..arcToPoint(
          Offset(cx + radius, cy),
          radius: Radius.circular(radius),
          clockwise: false,
        )
        ..cubicTo(
          cx + radius,
          cy - 12,
          cx + radius + 4,
          host.top,
          cx + radius + shoulder,
          host.top,
        );
    }
    return path
      ..lineTo(host.right - corner, host.top)
      ..quadraticBezierTo(host.right, host.top, host.right, host.top + corner)
      ..lineTo(host.right, host.bottom)
      ..close();
  }
}
