// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
// Import the MQTT client packages.
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';



void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sesli Kontrol',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const SpeechScreen(),
    );
  }
}

class SpeechScreen extends StatefulWidget {
  const SpeechScreen({Key? key}) : super(key: key);

  @override
  State<SpeechScreen> createState() => _SpeechScreenState();
}

class _SpeechScreenState extends State<SpeechScreen> {
  String _brokerAddress = '139.179.16.69';
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  String _text = 'Kayıt butonuna basın ve konuşmaya başlayın';
  double _confidence = 1.0;
  List<String> _transcriptions = [];

  // MQTT client variables
  late MqttServerClient _mqttClient;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _setupMqtt();
  }

  // Initialize speech recognition.
  void _initSpeech() async {
    await Permission.microphone.request();
    await _speech.initialize(
      onStatus: (status) {
        print('Status: $status');
        if (status == 'done') {
          setState(() => _isListening = false);
        }
      },
      onError: (errorNotification) {
        setState(() {
          _isListening = false;
          _text = 'Hata: Ses tanınmadı...';
        });
      },
    );
  }

  void _updateBrokerAddress(String newAddress) {
    // Disconnect the current MQTT client if connected.
    if (_mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
      _mqttClient.disconnect(); // Remove the await keyword since disconnect returns void.
    }

    setState(() {
      _brokerAddress = newAddress;
    });

    _setupMqtt(); // Reconnect using the new broker address.
  }


  void _showSettingsDialog() {
    final TextEditingController _controller =
    TextEditingController(text: _brokerAddress);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Broker Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Show the current broker address
              Text('Current Broker: $_brokerAddress'),
              const SizedBox(height: 10),
              // Input field with the current broker pre-populated
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'Enter new broker address',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Connect'),
              onPressed: () {
                String newBrokerAddress = _controller.text.trim();
                if (newBrokerAddress.isNotEmpty) {
                  _updateBrokerAddress(newBrokerAddress);
                }
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }



  // Setup MQTT client and connect to the broker.
  void _setupMqtt() async {
    // Create the MQTT client pointing to the new broker address.
    _mqttClient = MqttServerClient(_brokerAddress, '');
    _mqttClient.port = 1883;
    _mqttClient.logging(on: true);
    _mqttClient.keepAlivePeriod = 20;

    // Configure the connection message.
    final connMess = MqttConnectMessage()
        .withClientIdentifier('flutter_client_${DateTime.now().millisecondsSinceEpoch}')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _mqttClient.connectionMessage = connMess;

    try {
      print('Connecting to MQTT broker $_brokerAddress...');
      await _mqttClient.connect();
    } catch (e) {
      print('MQTT client exception: $e');
      _mqttClient.disconnect();
      return;
    }

    if (_mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
      print('MQTT client connected');
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendHeartbeat();
      });
    } else {
      print('MQTT connection failed - state is ${_mqttClient.connectionStatus?.state}');
      _mqttClient.disconnect();
    }
  }

  // Sends a heartbeat message to the topic "System/Stt/Heartbeat".
  void _sendHeartbeat() {
    const topic = 'system/stt/heartbeat';
    final builder = MqttClientPayloadBuilder();
    builder.addString('alive'); // You can change the payload as needed.
    _mqttClient.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    print('Heartbeat sent to $topic');
  }

  // Publish the transcribed text via MQTT.
  void _publishTranscription(String transcription) {
    const topic = 'system/stt/output';
    final builder = MqttClientPayloadBuilder();
    builder.addString(transcription);
    _mqttClient.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    print('Published transcription to $topic: "$transcription"');
  }

  // Start listening for speech.
  void _startListening() async {
    if (!_isListening) {
      var available = await _speech.initialize(
        onStatus: (status) => print('onStatus: $status'),
        onError: (errorNotification) => print('onError: $errorNotification'),
      );

      if (available) {
        setState(() {
          _isListening = true;
          _text = 'Dinleniyor...';
        });

        await _speech.listen(
          onResult: (result) {
            setState(() {
              _text = result.recognizedWords;
              if (result.hasConfidenceRating && result.confidence > 0) {
                _confidence = result.confidence;
              }
            });
            if (result.finalResult) {
              setState(() {
                _transcriptions.add(result.recognizedWords);
              });
              // Publish the final transcription via MQTT.
              _publishTranscription(result.recognizedWords);
            }
          },
        );
      } else {
        setState(() => _text = 'Sesli Kontrol kullanılamıyor');
      }
    }
  }

  // Stop listening for speech.
  void _stopListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    }
  }

  @override
  void dispose() {
    // Cancel the heartbeat timer and disconnect MQTT client.
    _heartbeatTimer?.cancel();
    _mqttClient.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sesli Kontrol'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.all(30.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _text,
                    style: const TextStyle(
                      fontSize: 24.0,
                      fontWeight: FontWeight.w400,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Doğruluk: ${(_confidence * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      fontSize: 16.0,
                      fontWeight: FontWeight.w200,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (_transcriptions.isNotEmpty) ...[
                    const Divider(height: 30),
                    const Text(
                      'Önceki Komutlar:',
                      style: TextStyle(
                        fontSize: 18.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...List.generate(_transcriptions.length, (index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          _transcriptions[index],
                          style: const TextStyle(fontSize: 16.0),
                        ),
                      );
                    }).reversed,
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FloatingActionButton(
                  onPressed: _isListening ? _stopListening : _startListening,
                  child: Icon(_isListening ? Icons.stop : Icons.mic),
                  tooltip: _isListening ? 'Kaydı Durdur' : 'Kayda Başla',
                ),
                if (_transcriptions.isNotEmpty)
                  FloatingActionButton(
                    onPressed: () {
                      setState(() {
                        _transcriptions.clear();
                      });
                    },
                    child: const Icon(Icons.clear),
                    tooltip: 'Geçmişi Temizle',
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
