import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/theme/app_colors.dart';
import 'package:errand/widgets/options_modal_sheet.dart';

void main() {
  testWidgets('OptionsModalSheet renders title and subtitle when provided', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOptionsModalSheet<void>(
                context,
                title: 'Conversation Title',
                subtitle: 'A helpful subtitle',
                options: [
                  SheetOption(
                    title: 'Normal Option',
                    icon: Icons.star_outline,
                    onTap: () {},
                  ),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Conversation Title'), findsOneWidget);
    expect(find.text('A helpful subtitle'), findsOneWidget);
    expect(find.text('Normal Option'), findsOneWidget);
    expect(find.byIcon(Icons.star_outline), findsOneWidget);
  });

  testWidgets('OptionsModalSheet renders without title and subtitle cleanly', (tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOptionsModalSheet<void>(
                context,
                options: [
                  SheetOption(
                    title: 'Copy',
                    icon: Icons.copy_rounded,
                    onTap: () {
                      tapped = true;
                    },
                  ),
                  SheetOption(
                    title: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    type: SheetOptionType.destructive,
                    onTap: () {},
                  ),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    final deleteText = tester.widget<Text>(find.text('Delete'));
    expect(deleteText.style?.color, kDanger);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(tapped, isTrue);
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('OptionsModalSheet renders items with null onTap without dismissal', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOptionsModalSheet<void>(
                context,
                title: 'Release Notes',
                isScrollControlled: true,
                options: const [
                  SheetOption(
                    title: 'Feature A',
                    icon: Icons.check_circle_outline_rounded,
                    onTap: null,
                  ),
                  SheetOption(
                    title: 'Feature B',
                    icon: Icons.check_circle_outline_rounded,
                    onTap: null,
                  ),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Release Notes'), findsOneWidget);
    expect(find.text('Feature A'), findsOneWidget);
    expect(find.text('Feature B'), findsOneWidget);

    final itemText = tester.widget<Text>(find.text('Feature A'));
    expect(itemText.style?.color, kText);

    // Tapping an item with null onTap does not dismiss the modal sheet
    await tester.tap(find.text('Feature A'));
    await tester.pumpAndSettle();

    expect(find.text('Release Notes'), findsOneWidget);
    expect(find.text('Feature A'), findsOneWidget);
  });

  testWidgets('OptionsModalSheet respects 75% screen height limit with many items', (tester) async {
    const screenHeight = 800.0;
    tester.view.physicalSize = const Size(400, screenHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOptionsModalSheet<void>(
                context,
                title: 'Release Notes',
                isScrollControlled: true,
                options: List.generate(
                  30,
                  (i) => SheetOption(
                    title: 'Item $i - description of feature',
                    icon: Icons.check_circle_outline_rounded,
                    onTap: null,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final sheetFinder = find.byType(OptionsModalSheet);
    expect(sheetFinder, findsOneWidget);

    final sheetSize = tester.getSize(sheetFinder);
    expect(sheetSize.height, lessThanOrEqualTo(screenHeight * 0.75 + 1.0));
  });

  testWidgets('OptionsModalSheet aligns leading icon with top line of multi-line text', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    const longNote =
        'feat(models, ui): sort models by release date in model picker with extensive description across multiple lines to test vertical alignment';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showOptionsModalSheet<void>(
                context,
                title: 'Release Notes',
                subtitle: 'Version 0.6.2',
                isScrollControlled: true,
                options: const [
                  SheetOption(
                    title: longNote,
                    icon: Icons.check_circle_outline_rounded,
                    onTap: null,
                  ),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final iconTop = tester.getTopLeft(find.byIcon(Icons.check_circle_outline_rounded)).dy;
    final textTop = tester.getTopLeft(find.text(longNote)).dy;
    final textHeight = tester.getSize(find.text(longNote)).height;

    // Text must span multiple lines (height > 20)
    expect(textHeight, greaterThan(30));
    // Icon top must be aligned with the first line (difference <= 4px), not in the middle (which would be textHeight/2)
    expect((iconTop - textTop).abs(), lessThanOrEqualTo(4.0));
  });
}
