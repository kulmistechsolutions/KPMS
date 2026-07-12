import 'package:web/web.dart' as web;

Future<bool> kpmsLaunchExternalUrl(String url) async {
  web.window.open(url, '_blank');
  return true;
}
