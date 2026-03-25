import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionsScreen extends StatefulWidget {
  final VoidCallback? onAllPermissionsGranted;

  const PermissionsScreen({super.key, this.onAllPermissionsGranted});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  // Permission statuses
  bool _cameraGranted = false;
  bool _notificationGranted = false;
  bool _locationGranted = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  /// Check current status of all permissions
  Future<void> _checkPermissions() async {
    setState(() => _isLoading = true);

    try {
      // Add timeout to prevent hanging
      final results = await Future.wait([
        Permission.camera.status,
        Permission.notification.status,
        Permission.locationWhenInUse.status,
      ]).timeout(const Duration(seconds: 3), onTimeout: () {
        // Return denied status on timeout to unblock UI
        return [
          PermissionStatus.denied,
          PermissionStatus.denied,
          PermissionStatus.denied
        ];
      });

      final cameraStatus = results[0];
      final notificationStatus = results[1];
      final locationStatus = results[2];

      if (mounted) {
        setState(() {
          _cameraGranted = cameraStatus.isGranted;
          _notificationGranted = notificationStatus.isGranted;
          _locationGranted = locationStatus.isGranted;
          _isLoading = false;
        });

        // If all permissions are granted, proceed
        if (_cameraGranted && _notificationGranted && _locationGranted) {
          _proceedToHome();
        }
      }
    } catch (e) {
      debugPrint("Error checking permissions: $e");
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Navigate to home screen after saving preferences
  Future<void> _proceedToHome() async {
    // Just call the callback - let the parent handle navigation/storage
    // This allows the callback to handle the "permissions_completed" flag and navigation
    widget.onAllPermissionsGranted?.call();
  }

  /// Request a specific permission
  Future<void> _requestPermission(Permission permission) async {
    final status = await permission.request();

    if (status.isPermanentlyDenied) {
      // Open app settings if permanently denied
      await openAppSettings();
    }

    // Re-check all permissions after request
    await _checkPermissions();
  }

  /// Request all permissions at once
  Future<void> _requestAllPermissions() async {
    await [
      Permission.camera,
      Permission.notification,
      Permission.locationWhenInUse,
      Permission.storage,
    ].request();

    await _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF1A237E), // Deep indigo
              const Color(0xFF3949AB), // Lighter indigo
              const Color(0xFF5C6BC0), // Even lighter
            ],
          ),
        ),
        child: SafeArea(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              : Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 40),

                      // Header Icon
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(26),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.security_rounded,
                          size: 40,
                          color: Colors.white,
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Title
                      const Text(
                        'App Permissions',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 12),

                      // Subtitle
                      Text(
                        'We need a few permissions to provide you with the best experience',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white.withAlpha(179),
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 48),

                      // Permission Cards
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              _buildPermissionCard(
                                icon: Icons.camera_alt_rounded,
                                title: 'Camera',
                                description:
                                    'Required to scan QR codes and take photos',
                                isGranted: _cameraGranted,
                                onRequest: () =>
                                    _requestPermission(Permission.camera),
                              ),
                              const SizedBox(height: 16),
                              _buildPermissionCard(
                                icon: Icons.notifications_rounded,
                                title: 'Notifications',
                                description:
                                    'Stay updated with important alerts and updates',
                                isGranted: _notificationGranted,
                                onRequest: () =>
                                    _requestPermission(Permission.notification),
                              ),
                              const SizedBox(height: 16),
                              _buildPermissionCard(
                                icon: Icons.location_on_rounded,
                                title: 'Location',
                                description:
                                    'Find nearby stores and track deliveries',
                                isGranted: _locationGranted,
                                onRequest: () => _requestPermission(
                                    Permission.locationWhenInUse),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Grant All Button
                      if (!_allPermissionsGranted)
                        ElevatedButton(
                          onPressed: _requestAllPermissions,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF1A237E),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.check_circle_rounded, size: 24),
                              SizedBox(width: 12),
                              Text(
                                'Grant All Permissions',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Continue Button (when all permissions granted)
                      if (_allPermissionsGranted)
                        ElevatedButton(
                          onPressed: _proceedToHome,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.greenAccent.shade400,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.arrow_forward_rounded, size: 24),
                              SizedBox(width: 12),
                              Text(
                                'Continue',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Skip Button (Removed to enforce permissions)
                      // if (!_allPermissionsGranted)
                      //   TextButton(
                      //     onPressed: _proceedToHome,
                      //     child: Text(
                      //       'Skip for now',
                      //       style: TextStyle(
                      //         color: Colors.white.withAlpha(179),
                      //         fontSize: 14,
                      //       ),
                      //     ),
                      //   ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  bool get _allPermissionsGranted =>
      _cameraGranted && _notificationGranted && _locationGranted;

  Widget _buildPermissionCard({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required VoidCallback onRequest,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isGranted
              ? Colors.greenAccent.withAlpha(128)
              : Colors.white.withAlpha(51),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          // Icon Container
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isGranted
                  ? Colors.greenAccent.withAlpha(51)
                  : Colors.white.withAlpha(26),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              size: 28,
              color: isGranted ? Colors.greenAccent : Colors.white,
            ),
          ),

          const SizedBox(width: 16),

          // Text Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    if (isGranted) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.check_circle,
                        size: 18,
                        color: Colors.greenAccent.shade400,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withAlpha(179),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          // Action Button
          if (!isGranted)
            GestureDetector(
              onTap: onRequest,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Enable',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A237E),
                  ),
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withAlpha(51),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check,
                size: 20,
                color: Colors.greenAccent.shade400,
              ),
            ),
        ],
      ),
    );
  }
}
