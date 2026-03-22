import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../ffi/nav_bridge.dart';

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  double _crossTrack = 0;

  // TODO: podłączyć strumień pozycji GNSS (np. geolocator)
  void _onPositionUpdate(double lat, double lon, double accuracy) {
    final result = NavBridge.instance.update(
      lat: lat,
      lon: lon,
      accuracy: accuracy,
    );
    setState(() => _crossTrack = result.crossTrack);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AgriNav')),
      body: Stack(
        children: [
          FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(52.0, 19.0),
              initialZoom: 15,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              ),
              // TODO: PolylineLayer dla linii AB i śladu przejazdu
            ],
          ),
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Odchylenie: ${_crossTrack.toStringAsFixed(2)} m',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
