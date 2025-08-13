import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:mason/mason.dart';
import 'package:meta/meta.dart';
import 'package:serinus_cli/src/commands/generate/generate_models/models_analyzer.dart';
import 'package:serinus_cli/src/utils/config.dart';

/// {@template generate_command}
///
/// `serinus_cli sample`
/// A [Command] to exemplify a sub command
/// {@endtemplate}
class GenerateModelsCommand extends Command<int> {
  /// {@macro generate_command}
  GenerateModelsCommand({
    Logger? logger,
  }) : _logger = logger;

  /// [ArgResults] used for testing purposes only.
  @visibleForTesting
  ArgResults? testArgResults;

  /// [String] used for testing purposes only.
  @visibleForTesting
  String? testUsage;

  @override
  ArgResults get argResults => super.argResults ?? testArgResults!;

  String get usageString => testUsage ?? usage;

  @override
  String get description => 'Generate models for your Serinus application';

  @override
  String get name => 'models';

  final Logger? _logger;

  @override
  Future<int> run([String? output]) async {
    final Config config;
    try {
      config = await getProjectConfiguration(_logger!, deps: true);
    } catch (e) {
      _logger?.err('Failed to load project configuration: $e');
      return ExitCode.config.code;
    }
    final modelProgress = _logger.progress('Generating models...');
    final process = await Process.start(
      'dart',
      ['pub', 'run', 'build_runner', 'build', '-d'],
    );
    process.stderr.transform(utf8.decoder).listen(
          (data) => _logger.info(
            data.replaceAll('\n', ''),
          ),
        );
    process.stdout.transform(utf8.decoder).listen(
          (data) => _logger.info(
            data.replaceAll('\n', ''),
          ),
        );
    await process.exitCode;
    modelProgress.complete('Models generated successfully!');
    final modelProviderProgress = _logger.progress(
      'Generating model provider...',
    );
    await generateModelProvider(
      Directory.current.path,
      config.name,
      config,
      output,
    );
    modelProviderProgress.complete('✨ Model provider generated successfully!');
    return ExitCode.success.code;
  }

  Future<List<Model>> generateModelProvider(
    String path,
    String name,
    Config config, [
    String? output,
  ]) async {
    final modelProvider = File('${output ?? path}/lib/model_provider.dart');
    final modelsConfig = config.models;
    if (!modelProvider.existsSync()) {
      modelProvider.createSync(recursive: true);
    }
    final deserializeKeywords = (modelsConfig?.deserializeKeywords ?? [])..add(
      const DeserializeKeyword(keyword: 'fromJson'));
    final serializeKeywords = (modelsConfig?.serializeKeywords ?? [])..add(
      const SerializeKeyword(keyword: 'toJson'));
    final files = await _recursiveGetFiles(
      Directory('$path${Platform.pathSeparator}lib'),
      modelsConfig,
      serializeKeywords,
      deserializeKeywords,
    );
    final analyzer = ModelsAnalyzer();
    final models = await analyzer.analyze(
      files,
      modelsConfig,
      serializeKeywords,
      deserializeKeywords,
    );
    final modelProviderContent = await _getContent(models, name);
    modelProvider.writeAsStringSync(modelProviderContent);
    _logger?.info(
      '✨Added ${models.map((e) => e.name).join(', ')} to the model provider',
    );
    return models;
  }

  Future<List<File>> _recursiveGetFiles(
    Directory dir,
    ModelsConfig? config,
    List<SerializeKeyword> serializeKeywords,
    List<DeserializeKeyword> deserializeKeywords,
  ) async {
    final files = <File>[];
    final extensions = [
      '.mapper',
      '.freezed',
      '.g',
      ...(config?.extensions ?? []).map((e) => '.$e'),
    ];
    final entities = dir.listSync();
    final generatedEntities = <String>[];
    for (final entity in entities) {
      if (entity is File) {
        final path = entity.path
            .replaceAll(dir.path, '')
            .replaceAll(Platform.pathSeparator, '');
        if (generatedEntities.contains(path)) {
          files.add(entity);
          continue;
        }
        if (extensions.any(path.contains) && path.split('.').length > 2) {
          final generatedPath = path.split('.')
            ..removeWhere((element) => extensions.contains('.$element'));
          if (!generatedEntities.contains(generatedPath.join('.'))) {
            final filePath = entity.path.split(Platform.pathSeparator);
            // ignore: cascade_invocations
            filePath
              ..removeLast()
              ..add(generatedPath.join('.'));
            files.add(
              File(
                filePath.join(Platform.pathSeparator),
              ),
            );
          }
          continue;
        }
        final content = entity.readAsStringSync();
        if (content.contains('class') &&
            (serializeKeywords.any((e) => content.contains(e.keyword)) ||
                deserializeKeywords.any((e) => content.contains(e.keyword))) &&
            !entity.path.endsWith('model_provider.dart')) {
          files.add(entity);
        }
      } else if (entity is Directory) {
        files.addAll(
          await _recursiveGetFiles(
            entity,
            config,
            serializeKeywords,
            deserializeKeywords,
          ),
        );
      }
    }
    return files;
  }

  Future<String> _getContent(List<Model> models, String name) async {
    final library = Library((b) {
      b.directives.addAll([
        Directive.import('package:serinus/serinus.dart'),
        for (final model in models.map((e) => e.filename).toSet())
          Directive.import(model)
      ]);
      b.body.add(
        Class((c) {
          c
            ..name = '${name.pascalCase}ModelProvider'
            ..extend = refer('ModelProvider');
          c.methods.add(
            Method((m) {
              m.annotations.add(
                refer('override'),
              );
              m
                ..name = 'toJsonModels'
                ..returns = refer('Map<Type, Function>')
                ..type = MethodType.getter
                ..body = Code('''
                return {
                  ${models.where((e) => e.hasToJson).map((e) {
                  return '${e.name}: (model) => (model as ${e.name}).${e.toJson}()';
                }).join(',\n')}
                };
              ''');
            }),
          );
          c.methods.add(
            Method((m) {
              m.annotations.add(
                refer('override'),
              );
              m
                ..name = 'fromJsonModels'
                ..returns = refer('Map<Type, Function>')
                ..type = MethodType.getter
                ..body = Code('''
                return {
                  ${models.where((e) => e.hasFromJson).map((e) {
                  return '${e.name}: (json) => ${e.fromJson}(json)';
                }).join(',\n')}
                };
              ''');
            }),
          );
          c.methods.add(
            Method((m) {
              m.annotations.add(
                refer('override'),
              );
              m
                ..name = 'from'
                ..returns = refer('Object')
                ..requiredParameters.addAll([
                  Parameter((p) {
                    p
                      ..name = 'model'
                      ..type = refer('Type');
                  }),
                  Parameter((p) {
                    p
                      ..name = 'json'
                      ..type = refer('Map<String, dynamic>');
                  }),
                ])
                ..body = Block.of([
                  const Code(r'''
                    if(fromJsonModels.containsKey(model)) {
                      return fromJsonModels[model]!(json);
                    }
                    throw UnsupportedError('Model $model not supported');
                  '''),
                ]);
            }),
          );
          c.methods.add(
            Method((m) {
              m.annotations.add(
                refer('override'),
              );
              m
                ..name = 'to<T>'
                ..returns = refer('Map<String, dynamic>')
                ..requiredParameters.add(
                  Parameter((p) {
                    p
                      ..name = 'model'
                      ..type = refer('T');
                  }),
                )
                ..body = Block.of([
                  const Code(r'''
                    if(toJsonModels.containsKey(T)) {
                      return toJsonModels[T]!(model) as Map<String, dynamic>;
                    }
                    throw UnsupportedError('Model $T not supported');
                  '''),
                ]);
            }),
          );
        }),
      );
    });
    return DartFormatter(
      languageVersion: DartFormatter.latestShortStyleLanguageVersion,
    ).format(
      library
          .accept(
            DartEmitter(
              orderDirectives: true,
              useNullSafetySyntax: true,
            ),
          )
          .toString(),
    );
  }
}
