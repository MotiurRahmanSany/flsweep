import 'package:test/test.dart';

import 'package:flsweep/src/ui/checklist.dart';

void main() {
  group('ChecklistState', () {
    test('starts with all rows unchecked by default', () {
      final state = ChecklistState(itemCount: 3);
      expect(state.checked, [false, false, false]);
      expect(state.noneSelected, isTrue);
      expect(state.allSelected, isFalse);
      expect(state.selectedIndices, isEmpty);
    });

    test('honors defaults', () {
      final state = ChecklistState(
        itemCount: 3,
        defaults: [true, false, true],
      );
      expect(state.selectedIndices, [0, 2]);
      expect(state.allSelected, isFalse);
      expect(state.noneSelected, isFalse);
    });

    test('rejects a non-positive item count', () {
      expect(() => ChecklistState(itemCount: 0), throwsArgumentError);
      expect(() => ChecklistState(itemCount: -1), throwsArgumentError);
    });

    test('rejects mismatched defaults length', () {
      expect(
        () => ChecklistState(itemCount: 3, defaults: [true]),
        throwsArgumentError,
      );
    });

    test('moveDown wraps from the last row to the first', () {
      final state = ChecklistState(itemCount: 3);
      state
        ..moveDown()
        ..moveDown()
        ..moveDown();
      expect(state.cursor, 0);
    });

    test('moveUp wraps from the first row to the last', () {
      final state = ChecklistState(itemCount: 3);
      state.moveUp();
      expect(state.cursor, 2);
    });

    test('toggleCurrent flips only the row under the cursor', () {
      final state = ChecklistState(itemCount: 3);
      state
        ..moveDown()
        ..toggleCurrent();
      expect(state.checked, [false, true, false]);
      expect(state.selectedIndices, [1]);
    });

    test('toggleAll selects everything when anything is unchecked', () {
      final state = ChecklistState(
        itemCount: 3,
        defaults: [true, false, true],
      );
      final result = state.toggleAll();
      expect(result, isTrue);
      expect(state.checked, [true, true, true]);
      expect(state.selectedIndices, [0, 1, 2]);
      expect(state.allSelected, isTrue);
    });

    test('toggleAll from all-selected clears everything', () {
      final state = ChecklistState(
        itemCount: 3,
        defaults: [true, true, true],
      );
      final result = state.toggleAll();
      expect(result, isFalse);
      expect(state.checked, [false, false, false]);
      expect(state.selectedIndices, isEmpty);
    });

    test('toggleAll from nothing-selected selects everything', () {
      final state = ChecklistState(itemCount: 2);
      state.toggleAll();
      expect(state.allSelected, isTrue);
      state.toggleAll();
      expect(state.noneSelected, isTrue);
    });

    test('toggleAll works on a single-row checklist', () {
      final state = ChecklistState(itemCount: 1);
      state.toggleAll();
      expect(state.checked, [true]);
      state.toggleAll();
      expect(state.checked, [false]);
    });
  });

  group('MultiSelectChecklist', () {
    test('rejects an empty option list', () {
      expect(
        () => MultiSelectChecklist(prompt: 'p', options: []),
        throwsArgumentError,
      );
    });

    test('rejects mismatched defaults length', () {
      expect(
        () => MultiSelectChecklist(
          prompt: 'p',
          options: ['a', 'b'],
          defaults: [true],
        ),
        throwsArgumentError,
      );
    });

    test('constructs with valid options', () {
      expect(
        MultiSelectChecklist(
          prompt: 'p',
          options: ['a', 'b'],
          colorEnabled: false,
        ),
        isA<MultiSelectChecklist>(),
      );
    });
  });
}
