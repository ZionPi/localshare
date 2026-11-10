# Local fork

Source: https://github.com/KasemJaffer/receive_sharing_intent
Revision: 2cea396843cd3ab1b5ec4334be4233864637874e (1.8.1)
License: MIT (see LICENSE).

Android changes:
- Distinguish EXTRA_STREAM/ClipData file URIs from EXTRA_TEXT. text/* streams are files.
- Read granted content/file URIs through ContentResolver instead of deriving storage paths.
- Cache each incoming file in a separate directory, preserving its display name.
- Preserve file captions, support ClipData fallback, and report read failures.
- Regression tests run with `cd android && ./gradlew :receive_sharing_intent:testDebugUnitTest`.

iOS and Dart plugin code are unchanged.
