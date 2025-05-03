// ignore_for_file: prefer_const_constructors, use_key_in_widget_constructors, library_private_types_in_public_api, prefer_const_literals_to_create_immutables

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LiveLocationWithRoutingMap(),
    );
  }
}

class LiveLocationWithRoutingMap extends StatefulWidget {
  @override
  _LiveLocationWithRoutingMapState createState() =>
      _LiveLocationWithRoutingMapState();
}

class _LiveLocationWithRoutingMapState
    extends State<LiveLocationWithRoutingMap> {
  late final MapController _mapController;
  LatLng _currentPosition = LatLng(0, 0);
  bool _locationFetched = false;
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  LatLng? _sourceLocation;
  LatLng? _destinationLocation;
  List<LatLng> _routePoints = [];
  List<LatLng> _crimeLocations = [];

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _requestPermissionAndGetLocation();
    _loadCrimeData(); // Load crime data at startup
  }

  Future<void> _requestPermissionAndGetLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      print("Location services are disabled.");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        print("Location permission denied.");
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      print("Location permissions are permanently denied.");
      return;
    }

    Geolocator.getPositionStream().listen((Position position) {
      LatLng newPosition = LatLng(position.latitude, position.longitude);

      setState(() {
        _currentPosition = newPosition;
        _locationFetched = true;
      });

      // 🔹 Prevent overriding the route if it's already displayed
      if (_routePoints.isEmpty) {
        _mapController.move(_currentPosition, 15.0);
      }

      if (_isNearCrimeLocation(newPosition)) {
        _showCrimeAlert();
      }
    });
  }

  Future<void> _loadCrimeData() async {
    try {
      String data = await DefaultAssetBundle.of(context)
          .loadString('assets/official_crime.test101_new.json');
      List<dynamic> jsonResult = jsonDecode(data);

      setState(() {
        _crimeLocations = jsonResult.map((item) {
          return LatLng(item['Latitude'], item['Longitude']);
        }).toList();
      });

      print("Loaded ${_crimeLocations.length} crime locations");
    } catch (e) {
      print("Error loading crime data: $e");
    }
  }

  bool _isNearCrimeLocation(LatLng position) {
    const double alertRadius = 500; // 500 meters
    int nearbyCrimeCount = 0;

    for (var crimeLocation in _crimeLocations) {
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        crimeLocation.latitude,
        crimeLocation.longitude,
      );

      if (distance <= alertRadius) {
        nearbyCrimeCount++;
        if (nearbyCrimeCount >= 1) {
          return true; // Trigger alert only once when at least one crime is within 500m
        }
      }
    }
    return false;
  }

  void _showCrimeAlert() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Warning!"),
        content: Text("You are near a high-crime area. Stay alert!"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("OK"),
          ),
        ],
      ),
    );
  }

  Future<void> _searchLocation(String query, bool isSource) async {
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=1');
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List data = json.decode(response.body);
      if (data.isNotEmpty) {
        final lat = double.parse(data[0]['lat']);
        final lon = double.parse(data[0]['lon']);
        setState(() {
          if (isSource) {
            _sourceLocation = LatLng(lat, lon);
          } else {
            _destinationLocation = LatLng(lat, lon);
          }
        });
        if (_sourceLocation != null && _destinationLocation != null) {
          _getRoute();
        }
      }
    }
  }

  Future<void> _getRoute() async {
    if (_sourceLocation == null || _destinationLocation == null) return;

    final url = Uri.parse(
        'http://router.project-osrm.org/route/v1/driving/${_sourceLocation!.longitude},${_sourceLocation!.latitude};${_destinationLocation!.longitude},${_destinationLocation!.latitude}?geometries=geojson');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List coordinates = data['routes'][0]['geometry']['coordinates'];

      setState(() {
        _routePoints =
            coordinates.map((coord) => LatLng(coord[1], coord[0])).toList();
      });

      // Move the map to fit the route
      _moveMapToRoute();
    }
  }

// Function to adjust the map to fit the route
  void _moveMapToRoute() {
    if (_routePoints.isEmpty) return;

    double minLat =
        _routePoints.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    double maxLat =
        _routePoints.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    double minLon =
        _routePoints.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    double maxLon =
        _routePoints.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    LatLngBounds bounds = LatLngBounds(
      LatLng(minLat, minLon),
      LatLng(maxLat, maxLon),
    );

    // Update camera view to fit the route
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: EdgeInsets.all(50), // Adjust padding to ensure a good fit
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Location & Routing')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentPosition,
              initialZoom: 14.0, // 🔹 Reduce zoom level to limit tile requests
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.de/{z}/{x}/{y}.png', // Alternative OSM tile server
                subdomains: ['a', 'b', 'c'],
                userAgentPackageName: 'com.example.app',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      color: Colors.blue,
                      strokeWidth: 5,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_locationFetched)
                    Marker(
                      point: _currentPosition,
                      width: 50,
                      height: 50,
                      child:
                          Icon(Icons.my_location, color: Colors.blue, size: 40),
                    ),
                  if (_sourceLocation != null)
                    Marker(
                      point: _sourceLocation!,
                      width: 50,
                      height: 50,
                      child: Icon(Icons.location_pin,
                          color: Colors.green, size: 40),
                    ),
                  if (_destinationLocation != null)
                    Marker(
                      point: _destinationLocation!,
                      width: 50,
                      height: 50,
                      child:
                          Icon(Icons.location_pin, color: Colors.red, size: 40),
                    ),
                  ..._crimeLocations.map(
                    (crime) => Marker(
                      point: crime,
                      width: 40,
                      height: 40,
                      child: Icon(Icons.warning, color: Colors.red, size: 30),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 20,
            left: 15,
            right: 15,
            child: Column(
              children: [
                _buildSearchBox("Enter source", _sourceController, true),
                const SizedBox(height: 10),
                _buildSearchBox(
                    "Enter destination", _destinationController, false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBox(
      String hint, TextEditingController controller, bool isSource) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        suffixIcon: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            _searchLocation(controller.text, isSource);
          },
        ),
      ),
    );
  }
}
