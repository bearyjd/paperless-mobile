import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';

part 'ai_chat_state.dart';

class AiChatCubit extends Cubit<AiChatState> {
  final String serverUrl;
  final String apiKey;
  final Dio _dio;

  AiChatCubit({
    required this.serverUrl,
    required this.apiKey,
  })  : _dio = Dio(BaseOptions(
          baseUrl: serverUrl.endsWith('/') ? serverUrl : '$serverUrl/',
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'x-api-key': apiKey,
          },
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 120),
          followRedirects: true,
          maxRedirects: 5,
        )),
        super(const AiChatState());

  /// Sends a chat message using Paperless-AI's RAG ask endpoint.
  Future<void> sendMessage(String message) async {
    final userMessage = ChatMessage(role: 'user', content: message);
    emit(state.copyWith(
      messages: [...state.messages, userMessage],
      isLoading: true,
    ));

    try {
      final response = await _dio.post(
        'api/rag/ask',
        data: jsonEncode({'question': message}),
      );

      final data = response.data;
      String content;
      List<DocumentReference> references = [];

      if (data is Map) {
        // RAG ask response format: {context, sources, query}
        content = data['context'] ??
            data['answer'] ??
            data['response'] ??
            data.toString();

        // Parse source documents from RAG response
        final sources = data['sources'];
        if (sources is List) {
          references = sources
              .map((r) {
                if (r is Map) {
                  return DocumentReference(
                    id: r['doc_id'] ?? r['document_id'] ?? r['id'] ?? 0,
                    title: r['title'] ?? r['document_title'] ?? '',
                  );
                }
                return null;
              })
              .whereType<DocumentReference>()
              .toList();
        }
      } else {
        content = data.toString();
      }

      final assistantMessage = ChatMessage(
        role: 'assistant',
        content: content,
        references: references,
      );

      emit(state.copyWith(
        messages: [...state.messages, assistantMessage],
        isLoading: false,
      ));
    } catch (e) {
      final errorMessage = ChatMessage(
        role: 'assistant',
        content: 'Error: ${e.toString()}',
      );
      emit(state.copyWith(
        messages: [...state.messages, errorMessage],
        isLoading: false,
      ));
    }
  }

  Future<List<Map<String, dynamic>>> semanticSearch(String query) async {
    try {
      final response = await _dio.post(
        'api/rag/search',
        data: jsonEncode({'query': query}),
      );
      final data = response.data;
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      }
      if (data is Map && data['sources'] != null) {
        return (data['sources'] as List).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // Note: Paperless-AI does not expose a classification API endpoint.
  // Classification happens internally via its cron-based document scanning.
  // This uses the RAG ask endpoint as a workaround to suggest classifications.
  Future<Map<String, dynamic>?> autoClassify(int documentId) async {
    try {
      final response = await _dio.post(
        'api/rag/ask',
        data: jsonEncode({
          'question':
              'What document type, correspondent, and tags would you suggest for document ID $documentId?',
        }),
      );
      if (response.data is Map) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> testConnection(String serverUrl, String apiKey) async {
    try {
      final baseUrl = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
      final dio = Dio(BaseOptions(
        baseUrl: baseUrl,
        headers: {
          if (apiKey.isNotEmpty) 'x-api-key': apiKey,
        },
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        followRedirects: true,
        maxRedirects: 5,
      ));
      // Try the health endpoint first, fall back to RAG status
      try {
        final response = await dio.get('health');
        return response.statusCode == 200;
      } catch (_) {
        final response = await dio.get('api/rag/status');
        return response.statusCode == 200;
      }
    } catch (_) {
      return false;
    }
  }
}
