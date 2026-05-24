# Qdrant Vector Database — Hướng Dẫn Sử Dụng

## 1. Qdrant là gì?

Qdrant là vector database mã nguồn mở viết bằng Rust, tối ưu cho tìm kiếm similarity (ANN search). Qdrant hỗ trợ:
- Tìm kiếm vector cosine, dot product, Euclidean distance
- Payload filtering (lọc kết hợp metadata)
- Sparse + dense hybrid search
- Giao thức gRPC và REST

## 2. Kiến Trúc Qdrant

Qdrant tổ chức dữ liệu theo cấu trúc phân cấp:

```
Cluster
  └── Collections (tương đương "bảng" trong SQL)
        └── Points (vector + payload)
              ├── vector: [0.1, 0.3, ..., 0.8]  (384 chiều)
              └── payload: {"doc_id": "abc", "text": "...", "chunk_idx": 0}
```

Mỗi **Point** gồm:
- `id`: UUID hoặc số nguyên không âm
- `vector`: mảng số thực (embedding)
- `payload`: JSON metadata tùy ý

## 3. Tạo Collection

```python
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams

client = QdrantClient(host="localhost", grpc_port=6334, prefer_grpc=True)

client.create_collection(
    collection_name="documents",
    vectors_config=VectorParams(size=384, distance=Distance.COSINE),
)
```

**Distance metrics:**
- `COSINE`: phù hợp nhất cho embedding ngữ nghĩa, chuẩn hóa theo magnitude
- `DOT`: nhanh hơn, phù hợp khi vector đã normalize
- `EUCLID`: khoảng cách Euclidean, ít dùng cho NLP

## 4. Upsert Vectors

```python
from qdrant_client.models import PointStruct

client.upsert(
    collection_name="documents",
    points=[
        PointStruct(
            id="point-uuid-1",
            vector=[0.1, 0.2, ..., 0.9],
            payload={
                "doc_id": "doc123",
                "text": "Nội dung đoạn văn...",
                "chunk_idx": 0,
                "doc_title": "Tài liệu hướng dẫn",
            },
        )
    ],
)
```

Upsert có tính idempotent: nếu `id` đã tồn tại, dữ liệu sẽ được cập nhật.

## 5. Tìm Kiếm (Query)

```python
from qdrant_client.models import Filter, FieldCondition, MatchAny

results = client.query_points(
    collection_name="documents",
    query=[0.1, 0.2, ..., 0.9],    # query vector
    query_filter=Filter(
        must=[FieldCondition(key="doc_id", match=MatchAny(any=["doc123", "doc456"]))]
    ),
    limit=20,
    score_threshold=0.5,
    with_vectors=True,              # cần để tính MMR
).points
```

**Lưu ý**: `query_points()` thay thế API `search()` đã deprecated từ Qdrant client 1.7.0.

## 6. Xóa Vectors

```python
from qdrant_client.models import Filter, FilterSelector, FieldCondition, MatchValue

client.delete(
    collection_name="documents",
    points_selector=FilterSelector(
        filter=Filter(
            must=[FieldCondition(key="doc_id", match=MatchValue(value="doc123"))]
        )
    ),
)
```

Xóa theo filter thay vì xóa từng ID giúp dọn sạch toàn bộ chunk của một tài liệu.

## 7. Payload Indexing

Để lọc theo payload nhanh hơn, tạo index trên trường hay dùng:

```python
client.create_payload_index(
    collection_name="documents",
    field_name="doc_id",
    field_schema="keyword",
)
```

Không có payload index, Qdrant vẫn lọc được nhưng sẽ scan toàn bộ collection.

## 8. HNSW Index Parameters

Qdrant dùng HNSW (Hierarchical Navigable Small World) cho ANN search. Tham số quan trọng:

| Tham số | Default | Ý nghĩa |
|---------|---------|---------|
| `m` | 16 | Số kết nối mỗi nút trong đồ thị HNSW |
| `ef_construct` | 100 | Độ chính xác khi xây dựng index |
| `ef` (search) | 128 | Độ chính xác khi tìm kiếm |

Tăng `m` và `ef_construct` → chính xác hơn nhưng dùng nhiều RAM và thời gian index hơn.

## 9. Capacity và Performance

Qdrant lưu index trong RAM để tìm kiếm nhanh. Ước tính RAM:

```
RAM ≈ num_vectors × vector_dim × 4 bytes × 1.5 (overhead HNSW)
```

Ví dụ: 100,000 vector 384 chiều ≈ 100,000 × 384 × 4 × 1.5 ≈ 230 MB RAM.

**Throughput:** Qdrant đạt 1,000–10,000 QPS trên hardware thông thường tùy kích thước collection và cấu hình HNSW.

## 10. Monitoring Qdrant

Qdrant expose Prometheus metrics tại `GET /metrics` (port 6333):

- `qdrant_collections_total_count`: số collection
- `qdrant_points_count{collection_name="..."}`: số point trong collection
- `qdrant_collection_search_duration_seconds`: histogram latency tìm kiếm

Dùng PodMonitor của kube-prometheus-stack để scrape metrics này trong Kubernetes.
