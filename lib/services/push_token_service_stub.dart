import 'package:fluttertoast/fluttertoast.dart';

class PushTokenService {
  static Future<void> registerToken(String userId) async {
    Fluttertoast.showToast(msg: "⚠️ Push notifications not supported on Web");
  }

  static void listenTokenRefresh(String userId) {
    Fluttertoast.showToast(msg: "⚠️ Token refresh not supported on Web");
  }
}
