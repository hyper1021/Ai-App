import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const SkyGenApp());
}

class SkyGenApp extends StatelessWidget {
  const SkyGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ImageAI(),
    );
  }
}

class ImageAI extends StatefulWidget {
  const ImageAI({super.key});

  @override
  State<ImageAI> createState() => _ImageAIState();
}

class _ImageAIState extends State<ImageAI> {
  final TextEditingController prompt = TextEditingController();

  bool loading = false;
  String imageUrl = "";
  String status = "Describe what you want to create";

  Future generateImage() async {
    if (prompt.text.trim().isEmpty) return;

    setState(() {
      loading = true;
      imageUrl = "";
      status = "Generating image...";
    });

    final res = await http.post(
      Uri.parse("https://gen-z-image.vercel.app/gen"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"q": prompt.text}),
    );

    final data = jsonDecode(res.body);
    final id = data["results"]["id"];

    await Future.delayed(const Duration(seconds: 6));
    await checkImage(id);
  }

  Future checkImage(String id) async {
    final res = await http.get(
      Uri.parse("https://gen-z-image.vercel.app/check?id=$id"),
    );

    final data = jsonDecode(res.body);

    setState(() {
      imageUrl = data["results"]["urls"][0];
      loading = false;
      status = "Done";
    });
  }

  Future downloadImage() async {
    final dir = await getExternalStorageDirectory();
    final file = File(
      "${dir!.path}/SkyGen_${DateTime.now().millisecondsSinceEpoch}.png",
    );

    final res = await http.get(Uri.parse(imageUrl));
    await file.writeAsBytes(res.bodyBytes);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Image saved")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff0b0b0b),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text(
                "SkyGen AI",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),

            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: loading
                    ? Column(
                        key: const ValueKey("loading"),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          SizedBox(
                            height: 60,
                            width: 60,
                            child: CircularProgressIndicator(strokeWidth: 4),
                          ),
                          SizedBox(height: 18),
                          Text(
                            "Creating image with AI...",
                            style: TextStyle(color: Colors.white70),
                          )
                        ],
                      )
                    : imageUrl.isEmpty
                        ? Center(
                            key: const ValueKey("empty"),
                            child: Text(
                              status,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 16,
                              ),
                            ),
                          )
                        : Column(
                            key: const ValueKey("image"),
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: Image.network(
                                      imageUrl,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 40,
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                  ),
                                  onPressed: downloadImage,
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.download),
                                      SizedBox(width: 10),
                                      Text(
                                        "Download Image",
                                        style: TextStyle(fontSize: 16),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            ],
                          ),
              ),
            ),

            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xff141414),
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: prompt,
                      style: const TextStyle(color: Colors.white),
                      maxLines: 3,
                      minLines: 1,
                      decoration: const InputDecoration(
                        hintText: "Type your image prompt...",
                        hintStyle: TextStyle(color: Colors.white54),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: loading ? null : generateImage,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withOpacity(0.9),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_upward,
                        color: Colors.black,
                      ),
                    ),
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
