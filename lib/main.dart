import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SkyGenAI(),
    );
  }
}

class SkyGenAI extends StatefulWidget {
  const SkyGenAI({super.key});

  @override
  State<SkyGenAI> createState() => _SkyGenAIState();
}

class _SkyGenAIState extends State<SkyGenAI> {
  TextEditingController prompt = TextEditingController();

  bool loading = false;
  String status = "";
  String imageUrl = "";
  String? taskId;

  /// generate image
  Future generateImage() async {
    setState(() {
      loading = true;
      status = "Generating image...";
      imageUrl = "";
    });

    final url = Uri.parse(
      "https://gen-z-image.vercel.app/gen"
      "?q=${Uri.encodeComponent(prompt.text)}"
      "&scale=1:1"
      "&resolution=1080p",
    );

    final res = await http.get(url);
    final data = jsonDecode(res.body);

    taskId = data["results"]["task_id"];

    await Future.delayed(const Duration(seconds: 6));
    await checkResult();
  }

  /// check result
  Future checkResult() async {
    final url = Uri.parse(
      "https://gen-z-image.vercel.app/check?task_id=$taskId",
    );

    final res = await http.get(url);
    final data = jsonDecode(res.body);

    imageUrl = data["results"]["urls"][0];

    setState(() {
      loading = false;
      status = "Done ✅";
    });
  }

  /// download image
  Future downloadImage() async {
    final dir = await getExternalStorageDirectory();
    final file =
        File("${dir!.path}/SkyGen_${DateTime.now().millisecondsSinceEpoch}.png");

    final res = await http.get(Uri.parse(imageUrl));
    await file.writeAsBytes(res.bodyBytes);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Image downloaded ✅")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("SkyGen AI")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(
            controller: prompt,
            decoration: const InputDecoration(
              hintText: "Describe your image...",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
              onPressed: loading ? null : generateImage,
              child: const Text("Generate")),
          const SizedBox(height: 20),
          if (loading) const CircularProgressIndicator(),
          Text(status),
          const SizedBox(height: 20),
          if (imageUrl.isNotEmpty)
            Column(
              children: [
                Image.network(imageUrl),
                ElevatedButton(
                    onPressed: downloadImage,
                    child: const Text("Download Image"))
              ],
            )
        ]),
      ),
    );
  }
}
