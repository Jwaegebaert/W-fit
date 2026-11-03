import 'dart:convert';
import 'dart:io';

import 'package:wfit/domain/catalog.dart';

Catalog loadTestCatalog() =>
    Catalog.fromJson(jsonDecode(File('assets/data/catalog.json').readAsStringSync()) as Map<String, dynamic>);
