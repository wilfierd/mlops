# RAG: Retrieval-Augmented Generation — Khái Niệm Cơ Bản

## 1. RAG là gì?

RAG (Retrieval-Augmented Generation) là kỹ thuật kết hợp hai bước:
1. **Retrieval** (truy xuất): tìm kiếm các đoạn tài liệu liên quan từ cơ sở dữ liệu vector
2. **Generation** (sinh văn bản): dùng LLM để tổng hợp câu trả lời từ các đoạn đó

RAG giải quyết vấn đề hallucination (ảo giác) của LLM bằng cách cung cấp context thực tế từ nguồn tài liệu đáng tin cậy.

## 2. Pipeline RAG điển hình

Một pipeline RAG gồm 5 bước chính:

| Bước | Tên | Mô tả |
|------|-----|-------|
| 1 | Chunking | Chia tài liệu thành các đoạn nhỏ (chunk) 200–500 token |
| 2 | Embedding | Chuyển mỗi chunk thành vector số thực (embedding) |
| 3 | Indexing | Lưu vector vào vector store (Qdrant, Weaviate, Pinecone) |
| 4 | Retrieval | Tìm top-k chunk gần nhất với câu hỏi |
| 5 | Generation | Đưa chunk vào prompt, gọi LLM sinh câu trả lời |

## 3. Embedding và Vector Store

Embedding là hàm ánh xạ văn bản thành vector số thực trong không gian có chiều cao (thường 384–1536 chiều). Hai văn bản có ý nghĩa tương tự sẽ có vector gần nhau theo độ đo cosine similarity.

**Công thức cosine similarity:**
```
sim(A, B) = (A · B) / (|A| × |B|)
```

Kết quả nằm trong khoảng [-1, 1]. Giá trị gần 1 nghĩa là rất giống nhau.

**Vector store** lưu trữ và tìm kiếm vector hiệu quả bằng thuật toán ANN (Approximate Nearest Neighbor) như HNSW. Qdrant sử dụng HNSW với độ phức tạp tìm kiếm O(log n).

## 4. Chunking Strategy

Cách chia chunk ảnh hưởng lớn đến chất lượng RAG:

- **Fixed-size chunking**: chia theo số token cố định (ví dụ 500 token), đơn giản nhưng có thể cắt ngang câu
- **Sentence chunking**: chia theo ranh giới câu hoặc đoạn văn, bảo toàn ngữ nghĩa tốt hơn
- **Semantic chunking**: nhóm các câu có embedding gần nhau, phức tạp nhưng chính xác nhất

**Overlap** (chồng lấp) giữa các chunk (thường 10–15% kích thước chunk) giúp tránh mất thông tin ở ranh giới.

## 5. Re-ranking

Sau khi retrieval lấy top-20 chunk, re-ranking chọn lại top-k tốt nhất:

- **Score threshold**: loại bỏ chunk có cosine similarity < 0.5
- **MMR (Maximal Marginal Relevance)**: cân bằng giữa relevance và diversity, tránh trả về nhiều chunk trùng nội dung
- **Cross-encoder**: mô hình nhỏ đánh giá lại mức độ liên quan giữa câu hỏi và chunk

**MMR score** = λ × relevance(q, c) − (1−λ) × max_similarity(c, selected)

Với λ = 0.5, MMR cân bằng bằng nhau giữa relevance và diversity.

## 6. Hallucination và Grounding

LLM có xu hướng sinh ra thông tin không có trong tài liệu (hallucination). Các kỹ thuật giảm hallucination trong RAG:

1. **Strict prompting**: yêu cầu LLM CHỈ trả lời từ CONTEXT cung cấp
2. **Citation**: yêu cầu LLM ghi nguồn [Nguồn 1], [Nguồn 2] cho mỗi khẳng định
3. **Low temperature**: đặt temperature = 0.1–0.2 để giảm sáng tạo không cần thiết
4. **No-context fallback**: nếu không tìm thấy chunk phù hợp, trả về "Tôi không tìm thấy thông tin trong tài liệu" thay vì bịa đặt

## 7. Latency Budget

Hệ thống RAG production cần tối ưu latency. Budget điển hình cho câu trả lời ≤ 18 giây:

| Bước | Budget |
|------|--------|
| Embedding | ≤ 200ms |
| Qdrant search | ≤ 100ms |
| MMR rerank | ≤ 20ms |
| vLLM generation | ≤ 15s |
| Network overhead | ≤ 500ms |

## 8. Các Model Embedding Phổ Biến

| Model | Chiều | Ngôn ngữ | Ghi chú |
|-------|-------|----------|---------|
| multilingual-e5-small | 384 | 100+ | Nhỏ, nhanh, hỗ trợ tiếng Việt |
| multilingual-e5-large | 1024 | 100+ | Chính xác hơn, chậm hơn |
| bge-m3 | 1024 | Đa ngôn ngữ | Hiệu năng cao |
| text-embedding-3-small | 1536 | Đa ngôn ngữ | OpenAI, cần API key |

**Lưu ý prefix e5**: Model E5 yêu cầu thêm prefix vào input:
- Query: `"query: <câu hỏi>"`
- Passage: `"passage: <đoạn văn>"`

Bỏ prefix giảm recall khoảng 10–15%.
