/// Keeps disk paths short while preserving a safe extension for other apps.
String buildStoredFileName(String fileName, String attachmentId) {
  final match = RegExp(r'\.([a-zA-Z0-9]{1,16})$').firstMatch(fileName);
  return match == null ? attachmentId : '$attachmentId.${match.group(1)}';
}
