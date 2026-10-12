// The device's location for pages' navigator.geolocation (see webby_geolocation_* in webby_ffi.h). The system's
// location service runs only while a page that was allowed to is waiting for a position or watching: GeoClue over
// D-Bus on Linux, Android's location services on phones.

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'bindings.dart';

class LocationBridge {
  LocationBridge._(this._wanted, this._setPosition, this._setError);

  static LocationBridge? _instance;
  static bool _looked = false;

  /// Null with a runtime that predates location support.
  static LocationBridge? of(WebbyBindings bindings) {
    if (_looked) return _instance;
    _looked = true;
    final lib = bindings.library;
    if (!lib.providesSymbol('webby_geolocation_wanted')) return null;
    return _instance = LocationBridge._(
      lib.lookupFunction<Int32 Function(), int Function()>('webby_geolocation_wanted'),
      lib.lookupFunction<Void Function(Double, Double, Double, Double, Double, Double, Double),
          void Function(double, double, double, double, double, double, double)>('webby_geolocation_set_position'),
      lib.lookupFunction<Void Function(Int32, Pointer<Utf8>), void Function(int, Pointer<Utf8>)>(
          'webby_geolocation_set_error'),
    );
  }

  static const _requested = 1;
  static const _errorPermissionDenied = 1;
  static const _errorPositionUnavailable = 2;

  /// A fix this recent answers a new one-off request straight away.
  static const _fresh = Duration(seconds: 30);
  /// How long the location service keeps running after the last page stopped wanting it.
  static const _linger = Duration(seconds: 5);
  /// After a failure, how long before trying the location service again.
  static const _retryAfter = Duration(seconds: 5);

  final int Function() _wanted;
  final void Function(double, double, double, double, double, double, double) _setPosition;
  final void Function(int, Pointer<Utf8>) _setError;

  StreamSubscription<Position>? _subscription;
  bool _starting = false;
  Position? _last;
  DateTime? _lastAt;
  DateTime? _idleSince;
  DateTime? _failedAt;

  /// Call after every pump.
  void poll() {
    final wanted = _wanted();
    final now = DateTime.now();
    if (wanted == 0) {
      if (_subscription != null) {
        _idleSince ??= now;
        if (now.difference(_idleSince!) >= _linger) _stop();
      }
      return;
    }
    _idleSince = null;

    // While the service runs it reports every move, so its last fix is the current position.
    final last = _last;
    if (wanted & _requested != 0 && last != null && (_subscription != null || now.difference(_lastAt!) < _fresh)) {
      _deliver(last);
      return;
    }
    if (_subscription != null || _starting) return;
    if (_failedAt != null && now.difference(_failedAt!) < _retryAfter) return;
    _start();
  }

  Future<void> _start() async {
    _starting = true;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        if (!await Geolocator.isLocationServiceEnabled()) {
          _fail(_errorPositionUnavailable, 'Location is turned off on this device');
          return;
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
          _fail(_errorPermissionDenied, 'Webby is not allowed to use the location');
          return;
        }
      }
      _subscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).listen(
        (position) {
          _last = position;
          _lastAt = DateTime.now();
          _failedAt = null;
          _deliver(position);
        },
        onError: (Object error) {
          _stop();
          _fail(error is PermissionDeniedException ? _errorPermissionDenied : _errorPositionUnavailable, '$error');
        },
        cancelOnError: true,
      );
    } catch (error) {
      _fail(_errorPositionUnavailable, '$error');
    } finally {
      _starting = false;
    }
  }

  void _stop() {
    _subscription?.cancel();
    _subscription = null;
    _idleSince = null;
  }

  void _deliver(Position p) {
    // geolocator reports 0 for what the platform didn't give.
    _setPosition(
      p.latitude,
      p.longitude,
      p.accuracy,
      p.altitudeAccuracy > 0 ? p.altitude : double.nan,
      p.altitudeAccuracy > 0 ? p.altitudeAccuracy : double.nan,
      p.speed > 0 && p.headingAccuracy > 0 ? p.heading : double.nan,
      p.speedAccuracy > 0 || p.speed > 0 ? p.speed : double.nan,
    );
  }

  void _fail(int code, String message) {
    debugPrint('webby: location: $message');
    _failedAt = DateTime.now();
    final text = message.toNativeUtf8();
    try {
      _setError(code, text);
    } finally {
      malloc.free(text);
    }
  }
}
