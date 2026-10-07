import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../services/push_token_service.dart';
import '../services/auth_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';

class WebLoginScreen extends StatefulWidget {
  final String url;

  const WebLoginScreen({super.key, required this.url});

  @override
  State<WebLoginScreen> createState() => _WebLoginScreenState();
}

class _WebLoginScreenState extends State<WebLoginScreen>
    with SingleTickerProviderStateMixin {
  late final WebViewController _controller;
  Timer? _authCheckTimer;
  bool _userProcessed = false; // prevent duplicate triggers
  bool _isLoading = true; // 👈 track WebView loading state
  bool _isFabExpanded = false; // Track FAB expansion state
  late String _currentUrl; // Track the current website URL
  String? _authJson; // Cached auth session JSON for auto-login injection

  // FAB position (draggable) - initialized in initState after getting screen size
  double _fabX = 16; // distance from right edge
  double _fabY = 100; // distance from bottom edge

  // Website options for quick switching
  static const List<Map<String, dynamic>> _websites = [
    {
      'name': 'Delivery',
      'url': 'https://delivery.megapaints.org',
      'icon': Icons.local_shipping_rounded,
      'color': Color(0xFF667eea),
    },
    {
      'name': 'Inventory',
      'url': 'https://qr-stock-management.megapaints.org',
      'icon': Icons.inventory_2_rounded,
      'color': Color(0xFF11998e),
    },
    {
      'name': 'Invoice',
      'url': 'https://invoice.megapaints.org',
      'icon': Icons.receipt_long_rounded,
      'color': Color(0xFFf093fb),
    },
  ];

  /// 🔔 Helper to log + toast
  void _logToast(String message) {
    debugPrint("[WebLoginScreen] $message");
    Fluttertoast.showToast(msg: message);
  }

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url; // Initialize with the starting URL
    
    // Preload auth session from SharedPreferences
    AuthService.getAuthJson().then((val) {
      if (mounted) {
        _authJson = val;
      }
    });

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'BlobDownloader',
        onMessageReceived: (JavaScriptMessage message) {
          _handleBlobData(message.message);
        },
      )
      ..addJavaScriptChannel(
        'FlutterWebView',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint(
              "[WebLoginScreen] 📨 Message from website: ${message.message}");
          _handleWebViewMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            // Log all navigation requests for debugging
            debugPrint(
                "[WebLoginScreen] 🔗 Navigation request: $url");

            // Detect download links by file extension or content-disposition
            // Also check for blob: URLs which indicate generated files
            if (url.startsWith('blob:')) {
              debugPrint(
                  "[WebLoginScreen] 📥 Blob download detected: $url");
              _logToast("📥 Downloading generated file...");
              _handleDownload(url);
              return NavigationDecision.prevent;
            }

            // Handle data: URIs (often used for generated PDFs)
            if (url.startsWith('data:')) {
              debugPrint("[WebLoginScreen] 📥 Data URI detected: ${url.substring(0, min<int>(url.length, 50))}...");
              _handleBlobData(url);
              return NavigationDecision.prevent;
            }

            // Handle phone calls, emails, sms, and maps (geo)
            if (url.startsWith('tel:') ||
                url.startsWith('mailto:') ||
                url.startsWith('sms:') ||
                url.startsWith('geo:')) {
              debugPrint("[WebLoginScreen] 📞 Launching external app: $url");
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }

            final uri = Uri.parse(url);
            final path = uri.path.toLowerCase();

            debugPrint("[WebLoginScreen] 📋 Path: $path");

            // Check if this is a downloadable file
            final downloadExtensions = [
              '.pdf',
              '.doc',
              '.docx',
              '.xls',
              '.xlsx',
              '.ppt',
              '.pptx',
              '.zip',
              '.rar',
              '.7z',
              '.jpg',
              '.jpeg',
              '.png',
              '.gif',
              '.svg',
              '.txt',
              '.csv',
              '.xml',
              '.json'
            ];

            final isDownload =
                downloadExtensions.any((ext) => path.endsWith(ext));

            debugPrint("[WebLoginScreen] 📥 Is download: $isDownload");

            if (isDownload) {
              debugPrint(
                  "[WebLoginScreen] 📥 Download detected: ${request.url}");
              _logToast("📥 Detected file: ${path.split('/').last}");
              _handleDownload(request.url);
              // Prevent the navigation so WebView doesn't try to load the file directly
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            debugPrint("[WebLoginScreen] 🚀 Page started loading: $url");
            setState(() => _isLoading = true);
            // Inject early script for reload interception
            _injectEarlyScript();
            // Automatically inject auth session
            _injectAuthSession();
          },
          onPageFinished: (url) async {
            //  _logToast("🌍 Page finished loading: $url");

            // Update current URL
            _currentUrl = url;

            // Inject blob click listener
            _injectBlobListener();

            // Ensure auth session is injected and synced
            await _injectAuthSession();

            // hide loading screen
            setState(() => _isLoading = false);

            // Start polling localStorage for 'auth'
            _startAuthPolling();
          },
          onUrlChange: (change) {
            debugPrint("[WebLoginScreen] 🔄 URL changed to: ${change.url}");
            if (change.url != null) {
              _currentUrl = change.url!;
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));

    // Configure Android WebView to handle permission requests (camera, microphone, etc.)
    _configureAndroidPermissions();
  }

  /// Automatically inject the unified auth session into website localStorage
  Future<void> _injectAuthSession() async {
    try {
      final authJson = _authJson ?? await AuthService.getAuthJson();
      if (authJson == null || authJson.isEmpty) return;
      _authJson = authJson;

      final escaped = jsonEncode(authJson);
      final js = """
        (function() {
          try {
            var current = window.localStorage.getItem('auth');
            if (!current || current === 'null' || current === '""' || current === '{}') {
              console.log('[Flutter] Auto-injecting unified auth session into localStorage');
              window.localStorage.setItem('auth', $escaped);
              
              // If page currently redirected to login screen, redirect to root
              if (window.location.hash.indexOf('login') !== -1) {
                console.log('[Flutter] Redirecting from login hash to root');
                window.location.hash = '#/';
              } else if (window.location.pathname.indexOf('login') !== -1) {
                console.log('[Flutter] Redirecting from login pathname to root');
                window.location.href = window.location.origin + '/#/';
              }
            }
          } catch(e) {
            console.error('[Flutter] Failed to set auth session:', e);
          }
        })();
      """;
      await _controller.runJavaScript(js);
    } catch (e) {
      debugPrint("[WebLoginScreen] Error injecting auth session: $e");
    }
  }

  /// Inject early script to set up reload bridge
  void _injectEarlyScript() {
    const js = """
      (function() {
        if (window._flutterBridgeReady) return;
        window._flutterBridgeReady = true;
        
        // Create a helper function that websites can call
        window.flutterReload = function() {
          if (window.FlutterWebView) {
            console.log('[Flutter] Calling FlutterWebView reload');
            window.FlutterWebView.postMessage('reload');
            return true;
          }
          return false;
        };
        
        console.log('[Flutter] Bridge ready, FlutterWebView available:', !!window.FlutterWebView);
      })();
    """;
    _controller.runJavaScript(js);
  }

  /// Inject JS listener to intercept blob clicks immediately
  void _injectBlobListener() {
    const js = """
      (function() {
        if (window.blobListenerInjected) return;
        window.blobListenerInjected = true;

        document.addEventListener('click', function(e) {
          var target = e.target;
          while (target && target.tagName !== 'A') {
            target = target.parentNode;
          }
          
          if (target && target.href && target.href.startsWith('blob:')) {
            console.log("Blob link clicked: " + target.href); // Log to console
            e.preventDefault(); // Stop navigation
            var url = target.href;
            var filename = target.getAttribute('download') || 'generated_file';
            
            // Use XHR to fetch blob data
            var xhr = new XMLHttpRequest();
            xhr.open('GET', url, true);
            xhr.responseType = 'blob';
            
            xhr.onload = function() {
              if (this.status === 200) {
                var blob = this.response;
                var reader = new FileReader();
                reader.readAsDataURL(blob);
                reader.onloadend = function() {
                  var result = {
                    type: 'blob',
                    data: reader.result,
                    filename: filename
                  };
                  BlobDownloader.postMessage(JSON.stringify(result));
                }
              } else {
                 BlobDownloader.postMessage(JSON.stringify({error: "XHR Status " + this.status}));
              }
            };
            xhr.onerror = function() {
              BlobDownloader.postMessage(JSON.stringify({error: "XHR Network Error"}));
            };
            xhr.send();
          }
        }, true);

        // Intercept reload by checking for syncing flag in sessionStorage
        if (window.FlutterWebView && !window._syncListenerAdded) {
          window._syncListenerAdded = true;
          
          // Check periodically if syncing flag was set, then trigger Flutter reload
          setInterval(function() {
            var syncing = sessionStorage.getItem('syncing');
            if (syncing === 'true') {
              console.log('[FlutterWebView] Syncing flag detected, triggering Flutter reload');
              sessionStorage.removeItem('syncing'); // Clear the flag
              window.FlutterWebView.postMessage('reload');
            }
          }, 100); // Check every 100ms
          
          console.log('[FlutterWebView] Sync listener installed');
        }
      })();
    """;
    _controller.runJavaScript(js);
  }

  /// Process blob URL if caught by NavigationDelegate (fallback)
  void _processBlobUrl(String blobUrl) {
    debugPrint(
        "[WebLoginScreen] 🔄 Fallback: Fetching blob via injected JS: $blobUrl");
    final js = """
      (function() {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', '$blobUrl', true);
        xhr.responseType = 'blob';
        xhr.onload = function(e) {
          if (this.status == 200) {
            var blob = this.response;
            var reader = new FileReader();
            reader.readAsDataURL(blob);
            reader.onloadend = function() {
              var result = {
                type: 'blob',
                data: reader.result,
                filename: 'generated_file.pdf'
              };
              BlobDownloader.postMessage(JSON.stringify(result));
            }
          } else {
             BlobDownloader.postMessage("ERROR: Fallback XHR Status " + this.status);
          }
        };
        xhr.onerror = function() {
          BlobDownloader.postMessage("ERROR: Fallback XHR Network Error");
        };
        xhr.send();
      })();
    """;
    _controller.runJavaScript(js);
  }

  /// Handle messages from the website via FlutterWebView channel
  void _handleWebViewMessage(String message) {
    switch (message.toLowerCase()) {
      case 'reload':
        debugPrint("[WebLoginScreen] 🔄 Reload requested by website");
        setState(() => _isLoading = true);
        _controller.reload();
        break;
      case 'goback':
        debugPrint("[WebLoginScreen] ⬅️ GoBack requested by website");
        _controller.goBack();
        break;
      default:
        debugPrint("[WebLoginScreen] ⚠️ Unknown message: $message");
    }
  }

  /// Configure Android-specific WebView permissions
  void _configureAndroidPermissions() {
    if (_controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;

      // Handle permission requests from the website (camera, microphone, etc.)
      androidController.setOnPlatformPermissionRequest((request) {
        debugPrint(
            "[WebLoginScreen] 🔐 Permission requested: ${request.types}");
        // Grant all requested permissions (camera, microphone, etc.)
        request.grant();
      });

      // Handle file upload / <input type="file"> requests from websites
      androidController.setOnShowFileSelector(
        (FileSelectorParams params) async {
          debugPrint(
              "[WebLoginScreen] 📂 File selector requested - acceptTypes: ${params.acceptTypes}, multiple: ${params.mode == FileSelectorMode.openMultiple}");

          try {
            // Try to request permissions first if needed
            await _checkAndRequestStoragePermission();

            // Determine file type filter from accept types
            FileType fileType = FileType.any;
            List<String>? allowedExtensions;

            if (params.acceptTypes.isNotEmpty) {
              final acceptTypesStr = params.acceptTypes.join(',').toLowerCase();
              
              bool hasImage = acceptTypesStr.contains('image/') || acceptTypesStr.contains('.jpg') || acceptTypesStr.contains('.png') || acceptTypesStr.contains('.jpeg');
              bool hasVideo = acceptTypesStr.contains('video/') || acceptTypesStr.contains('.mp4') || acceptTypesStr.contains('.mov');
              bool hasAudio = acceptTypesStr.contains('audio/') || acceptTypesStr.contains('.mp3') || acceptTypesStr.contains('.wav');
              bool hasDoc = acceptTypesStr.contains('application/') || acceptTypesStr.contains('text/') || acceptTypesStr.contains('.pdf') || acceptTypesStr.contains('.doc') || acceptTypesStr.contains('.csv') || acceptTypesStr.contains('.xls');

              if (hasDoc) {
                fileType = FileType.any;
              } else if (hasImage && !hasVideo && !hasAudio) {
                fileType = FileType.image;
              } else if (hasVideo && !hasImage && !hasAudio) {
                fileType = FileType.video;
              } else if (hasAudio && !hasImage && !hasVideo) {
                fileType = FileType.audio;
              } else if (hasImage || hasVideo || hasAudio) {
                fileType = FileType.media;
              }
            }

            final result = await FilePicker.platform.pickFiles(
              allowMultiple: params.mode == FileSelectorMode.openMultiple,
              type: fileType,
              allowedExtensions: allowedExtensions,
            );

            if (result != null && result.files.isNotEmpty) {
              final paths = result.files
                  .where((file) => file.path != null)
                  .map((file) => Uri.file(file.path!).toString())
                  .toList();
              debugPrint(
                  "[WebLoginScreen] ✅ Files selected: $paths");
              return paths;
            }

            debugPrint("[WebLoginScreen] ⚠️ File selection cancelled");
            return [];
          } catch (e) {
            debugPrint("[WebLoginScreen] ❌ File picker error: $e");
            _logToast("❌ Could not open file picker");
            return [];
          }
        },
      );

      // Handle geolocation permission requests from websites
      androidController.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (request) async {
          debugPrint(
              "[WebLoginScreen] 📍 Geolocation requested by: ${request.origin}");

          // Check if the app has location permission
          final locationStatus = await Permission.location.status;

          if (locationStatus.isGranted) {
            debugPrint("[WebLoginScreen] ✅ Granting geolocation to website");
            // Grant geolocation permission to the website
            return const GeolocationPermissionsResponse(
              allow: true,
              retain: true, // Remember this decision
            );
          } else {
            debugPrint(
                "[WebLoginScreen] ❌ App doesn't have location permission");
            // Request location permission from the user
            final result = await Permission.location.request();
            if (result.isGranted) {
              debugPrint(
                  "[WebLoginScreen] ✅ Location permission granted, allowing website");
              return const GeolocationPermissionsResponse(
                allow: true,
                retain: true,
              );
            } else {
              debugPrint("[WebLoginScreen] ❌ Location permission denied");
              _logToast("⚠️ Location permission required for this feature");
              return const GeolocationPermissionsResponse(
                allow: false,
                retain: false,
              );
            }
          }
        },
        onHidePrompt: () {
          debugPrint("[WebLoginScreen] 📍 Geolocation prompt hidden");
        },
      );

      // Enable media playback without user gesture (optional)
      androidController.setMediaPlaybackRequiresUserGesture(false);
    }
  }

  /// Handle file downloads
  Future<void> _handleDownload(String url) async {
    debugPrint("[WebLoginScreen] 📥 Download initiated: $url");

    if (url.startsWith('blob:')) {
      _processBlobUrl(url);
    } else if (url.startsWith('data:')) {
      _handleBlobData(url);
    } else {
      _downloadFile(url);
    }
  }

  /// Request storage permissions with support for Android 11+
  Future<bool> _checkAndRequestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // 1. Check Manage External Storage (Android 11+)
    if (await Permission.manageExternalStorage.isGranted) {
      return true;
    }

    // 2. Try to request Manage External Storage
    // This is required for writing to public Downloads folder on Android 11+
    // On older Android, this might just return restricted/denied, which we handle below
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) {
      return true;
    }

    // 3. Fallback: Check/Request regular Storage (Android < 11)
    if (await Permission.storage.isGranted) {
      return true;
    }

    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  /// Download file using http package
  Future<void> _downloadFile(String url) async {
    // Request storage permission first (supports Android 11+)
    if (!await _checkAndRequestStoragePermission()) {
      _logToast("⚠️ Storage permission required to save files");
      return;
    }

    _logToast("📥 Downloading file...");
    try {
      // Fetch User-Agent from WebView to mimic browser request
      final userAgentObj =
          await _controller.runJavaScriptReturningResult('navigator.userAgent');
      final userAgent = userAgentObj.toString().replaceAll('"', '').trim();

      debugPrint("[WebLoginScreen] 📡 GET $url");
      debugPrint("[WebLoginScreen] 👤 User-Agent: $userAgent");

      final response = await http.get(Uri.parse(url), headers: {
        'User-Agent': userAgent,
      });

      debugPrint("[WebLoginScreen] 📥 Response status: ${response.statusCode}");
      debugPrint(
          "[WebLoginScreen] 📋 Content-Type: ${response.headers['content-type']}");
      debugPrint(
          "[WebLoginScreen] 📏 Content-Length: ${response.bodyBytes.length} bytes");

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        Directory? dir;
        if (Platform.isAndroid) {
          dir = await getExternalStorageDirectory();
        }
        dir ??= await getApplicationDocumentsDirectory();

        // ... (existing filename logic)
        String filename = "download";
        final uri = Uri.parse(url);
        if (uri.pathSegments.isNotEmpty) {
          filename = uri.pathSegments.last;
        }

        if (!filename.contains('.') || filename.length > 50) {
          final contentType = response.headers['content-type'] ?? '';
          String ext = 'bin';
          if (contentType.contains('pdf')) {
            ext = 'pdf';
          } else if (contentType.contains('png')) {
            ext = 'png';
          } else if (contentType.contains('jpeg') ||
              contentType.contains('jpg')) {
            ext = 'jpg';
          } else if (contentType.contains('spreadsheet') ||
              contentType.contains('excel')) {
            ext = 'xlsx';
          } else if (contentType.contains('word') ||
              contentType.contains('doc')) {
            ext = 'docx';
          }

          if (!filename.contains('.')) {
            filename = "download_${DateTime.now().millisecondsSinceEpoch}.$ext";
          }
        }

        // Use public Downloads folder instead of app scoped
        String path;
        if (Platform.isAndroid) {
          path = '/storage/emulated/0/Download';
          // Create directory if it doesn't exist (unlikely for Downloads but good practice)
          final d = Directory(path);
          if (!await d.exists()) {
            // Fallback to app specific if public download dir doesn't exist?
            // Or try to create (might fail without permissions)
          }
        } else {
          path = dir?.path ?? (await getApplicationDocumentsDirectory()).path;
        }

        filename = filename.replaceAll(RegExp(r'[^\w\.-]'), '_');
        debugPrint("[WebLoginScreen] 💾 Saving to $path/$filename");

        final File file = File('$path/$filename');
        await file.writeAsBytes(bytes);

        _logToast("✅ Saved to $filename");

        final result = await OpenFilex.open(file.path);
        debugPrint(
            "[WebLoginScreen] 📂 Open result: ${result.type} - ${result.message}");

        if (result.type != ResultType.done) {
          // If internal open fails, try external launch as backup
          _logToast("⚠️ Opening externally...");
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
      } else {
        debugPrint("[WebLoginScreen] ❌ HTTP ${response.statusCode}");
        _logToast("❌ Download failed (HTTP ${response.statusCode})");
        // Fallback
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint("[WebLoginScreen] ❌ Download error: $e");
      _logToast("❌ Download failed. Opening browser...");
      // Fallback to launching URL
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (e2) {
        _logToast("❌ Could not open link");
      }
    }
  }

  /// Process base64 data received from JS
  Future<void> _handleBlobData(String message) async {
    try {
      // Check permissions first
      if (!await _checkAndRequestStoragePermission()) {
        _logToast("⚠️ Storage permission required to save files");
        return;
      }

      String base64Data = "";
      String extension = "pdf";

      // Detect extension from data URI if present
      if (message.startsWith('data:')) {
        try {
          final mimeType = message.split(':')[1].split(';')[0];
          if (mimeType.contains('image/png')) {
            extension = "png";
          } else if (mimeType.contains('image/jpeg')) {
            extension = "jpg";
          } else if (mimeType.contains('image/gif')) {
            extension = "gif";
          } else if (mimeType.contains('application/pdf')) {
            extension = "pdf";
          } else if (mimeType.contains('text/csv')) {
            extension = "csv";
          } else if (mimeType.contains('text/plain')) {
            extension = "txt";
          } else if (mimeType.contains('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')) {
            extension = "xlsx";
          } else if (mimeType.contains('application/vnd.ms-excel')) {
            extension = "xls";
          } else if (mimeType.contains('application/vnd.openxmlformats-officedocument.wordprocessingml.document')) {
            extension = "docx";
          }
        } catch (_) {}
      }

      String filename = "download_${DateTime.now().millisecondsSinceEpoch}.$extension";

      // Try to parse as JSON
      if (message.trim().startsWith('{')) {
        try {
          final json = jsonDecode(message);
          if (json['error'] != null) {
            debugPrint("[WebLoginScreen] ❌ JS Error: ${json['error']}");
            _logToast("❌ Download error: ${json['error']}");
            return;
          }
          base64Data = json['data'] ?? "";
          if (json['filename'] != null &&
              json['filename'].toString().isNotEmpty) {
            filename = json['filename'];
            if (!filename.contains('.')) filename += ".pdf"; // Default to pdf
          }
        } catch (e) {
          // JSON parse failed, assume raw string?
          debugPrint("[WebLoginScreen] ❌ Failed to parse JS message: $message");
          _logToast("❌ Failed to parse download data");
          return;
        }
      } else if (message.startsWith("ERROR:")) {
        _logToast("❌ ${message}");
        return;
      } else {
        // Legacy raw string support
        base64Data = message;
      }

      if (base64Data.isEmpty) {
        _logToast("❌ Downloaded data was empty");
        return;
      }

      final String cleanBase64 = base64Data.split(',').last;
      final Uint8List bytes = base64Decode(cleanBase64);

      // Use public Downloads folder
      String path;
      if (Platform.isAndroid) {
        path = '/storage/emulated/0/Download';
      } else {
        final dir = await getApplicationDocumentsDirectory();
        path = dir.path;
      }

      // Sanitize filename
      filename = filename.replaceAll(RegExp(r'[^\w\.-]'), '_');

      final File file = File('$path/$filename');
      await file.writeAsBytes(bytes);

      _logToast("✅ Saved to $filename");

      final result = await OpenFilex.open(file.path);
      debugPrint("[WebLoginScreen] 📂 Open result for blob: ${result.type}");

      if (result.type != ResultType.done) {
        _logToast("⚠️ Could not open file: ${result.message}");
        // Try opening with standard Android intent if open_filex fails
        try {
          await launchUrl(Uri.parse("file://${file.path}"));
        } catch (e) {
          // ignore
        }
      }
    } catch (e) {
      debugPrint("[WebLoginScreen] ❌ Blob processing error: $e");
      _logToast("❌ Error saving generated file");
    }
  }

  void _startAuthPolling() {
    _authCheckTimer?.cancel(); // clear any old timers
    _authCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_userProcessed) {
        await _checkLoggedInUser();
      }
    });
  }

  Future<void> _checkLoggedInUser() async {
    try {
      const jsCode = "window.localStorage.getItem('auth');";
      final result = await _controller.runJavaScriptReturningResult(jsCode);
      final resultStr = result.toString();

      if (resultStr.isNotEmpty && resultStr != 'null') {
        String raw = resultStr;

        if (raw.startsWith('"') && raw.endsWith('"')) {
          raw = raw.substring(1, raw.length - 1);
        }

        raw = raw.replaceAll(r'\"', '"').trim();
        Map<String, dynamic> data = jsonDecode(raw);

        final userId = data['user']?['id']?.toString() ?? "";

        if (userId.isNotEmpty) {
          // Keep session cache and SharedPreferences updated
          _authJson = raw;
          await AuthService.saveAuthJson(raw);

          if (!_userProcessed) {
            _userProcessed = true;
            _authCheckTimer?.cancel();
            await _onLoginSuccess(userId);
          }
        }
      } else {
        // If the user was logged in previously and web app cleared auth (logout), detect logout
        if (_userProcessed && (result.toString() == 'null' || result.toString().isEmpty)) {
          debugPrint("[WebLoginScreen] 🚪 Web logout detected from WebView");
          _authCheckTimer?.cancel();
          await AuthService.logout();
          if (mounted) {
            Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
          }
        }
      }
    } catch (e) {
      // Error parsing auth JSON
    }
  }

  Future<void> _onLoginSuccess(String userId) async {
    // _logToast("📡 Registering token for $userId...");
    await PushTokenService.registerToken(userId);
    PushTokenService.listenTokenRefresh(userId);
  }

  @override
  void dispose() {
    _authCheckTimer?.cancel();
    super.dispose();
  }

  /// Handle back button press - navigate back in WebView if possible
  Future<bool> _onBackPressed() async {
    // Close FAB if expanded
    if (_isFabExpanded) {
      setState(() => _isFabExpanded = false);
      return false;
    }

    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false; // Don't pop the screen
    }
    return true; // Pop the screen (go back to main)
  }

  /// Switch to a different website
  void _switchWebsite(String url) {
    setState(() {
      _isLoading = true;
      _isFabExpanded = false;
      _currentUrl = url; // Update current URL
    });
    _controller.loadRequest(Uri.parse(url));
  }

  /// Toggle FAB expansion
  void _toggleFab() {
    setState(() => _isFabExpanded = !_isFabExpanded);
  }

  String get _currentSiteName {
    for (var site in _websites) {
      if (_currentUrl.contains(Uri.parse(site['url'] as String).host)) {
        return site['name'] as String;
      }
    }
    return 'Portal';
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    const fabSize = 56.0;

    return PopScope(
      canPop: false, // We'll handle the pop manually
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        final shouldPop = await _onBackPressed();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        body: SafeArea(
          child: Column(
            children: [
              // Top Portal Control Bar
              _buildTopPortalBar(),

              // WebView Content + Overlays
              Expanded(
                child: Stack(
                  children: [
                    WebViewWidget(controller: _controller),

                    // Modern Dark Loading Overlay
                    if (_isLoading) _buildLoadingOverlay(),

                    // Overlay when FAB is expanded
                    if (_isFabExpanded)
                      GestureDetector(
                        onTap: _toggleFab,
                        child: Container(
                          color: Colors.black.withOpacity(0.65),
                        ),
                      ),

                    // Draggable Floating Action Button
                    Positioned(
                      right: _fabX,
                      bottom: _fabY,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Website options (shown when expanded)
                          if (_isFabExpanded) ..._buildWebsiteOptions(),

                          const SizedBox(height: 8),

                          // Draggable Main FAB
                          GestureDetector(
                            onPanUpdate: (details) {
                              setState(() {
                                _fabX -= details.delta.dx;
                                _fabY -= details.delta.dy;

                                _fabX = _fabX.clamp(
                                    0, screenSize.width - fabSize - 16);
                                _fabY = _fabY.clamp(
                                    0, screenSize.height - fabSize - 120);
                              });
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF6366F1).withOpacity(0.4),
                                    blurRadius: 16,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: FloatingActionButton(
                                onPressed: _toggleFab,
                                elevation: 0,
                                backgroundColor: _isFabExpanded
                                    ? const Color(0xFF374151)
                                    : const Color(0xFF4F46E5),
                                child: AnimatedRotation(
                                  turns: _isFabExpanded ? 0.125 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    _isFabExpanded
                                        ? Icons.close
                                        : Icons.swap_horiz_rounded,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Top Portal Control Bar with Back, Title, Reload and Progress Bar
  Widget _buildTopPortalBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withOpacity(0.08),
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                // Back Button
                IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white70,
                    size: 18,
                  ),
                  tooltip: 'Go Back',
                  onPressed: () async {
                    if (await _controller.canGoBack()) {
                      await _controller.goBack();
                    } else if (mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),

                // Portal Title Pill
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1117),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.07),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.lock_rounded,
                          color: Color(0xFF10B981),
                          size: 13,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Mega Paints • $_currentSiteName',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Reload Button
                IconButton(
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                  tooltip: 'Reload Page',
                  onPressed: () {
                    _controller.reload();
                  },
                ),

                // Home / Dashboard Button
                IconButton(
                  icon: const Icon(
                    Icons.dashboard_rounded,
                    color: Color(0xFF818CF8),
                    size: 20,
                  ),
                  tooltip: 'Main Hub',
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ),

          // Slim Loading Indicator
          if (_isLoading)
            const SizedBox(
              height: 2.5,
              child: LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
              ),
            ),
        ],
      ),
    );
  }

  /// Modern Dark Loading Overlay
  Widget _buildLoadingOverlay() {
    return Container(
      color: const Color(0xFF0D1117),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Glowing Logo Container
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF4F46E5).withOpacity(0.2),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Image.asset(
                "assets/logopng.png",
                width: 72,
                height: 72,
              ),
            ),
            const SizedBox(height: 24),

            // Portal Connection Text
            Text(
              'Connecting to $_currentSiteName...',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Injecting unified SSO session',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 26),

            // Progress Indicator
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 2.8,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build the website switcher buttons
  List<Widget> _buildWebsiteOptions() {
    return _websites.map((site) {
      final isCurrentSite = _currentUrl.contains(
        Uri.parse(site['url'] as String).host,
      );

      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // Modern Label Card
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isCurrentSite ? null : () => _switchWebsite(site['url']),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isCurrentSite
                          ? (site['color'] as Color).withOpacity(0.6)
                          : Colors.white.withOpacity(0.1),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        site['name'],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isCurrentSite
                              ? const Color(0xFFA5B4FC)
                              : Colors.white,
                        ),
                      ),
                      if (isCurrentSite) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Active',
                            style: TextStyle(
                              color: Color(0xFF34D399),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Mini FAB
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (site['color'] as Color).withOpacity(0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: FloatingActionButton.small(
                heroTag: site['name'],
                onPressed:
                    isCurrentSite ? null : () => _switchWebsite(site['url']),
                backgroundColor: isCurrentSite
                    ? Colors.grey.shade700
                    : site['color'] as Color,
                elevation: 0,
                child: Icon(
                  site['icon'] as IconData,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }
}

