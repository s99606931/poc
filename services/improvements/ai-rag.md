# ai-rag 서비스 개선 태스크 (POC 대응)

> **서비스**: `projects/10_alli-work/apps/ai-rag`
> **현재 포트**: 4006
> **기술**: FastAPI + LangGraph + Milvus 2.5 + Redis
> **POC 역할**: 규정 문서 지식베이스 핵심 (POC 2 규정 Q&A, POC 3 감사 규정 검색)
> **작성일**: 2026-04-21

> **📌 POC 확장 범위 요약**
> 기존 8개 라우터 (`upload_router`, `tenant_router`, `rerank_client` 등) 재사용.
> 핵심 작업: **규정 파티션 5종 생성 + 조(Article) 단위 청킹 모듈** 추가.
> 🔴 **P0-2 결정 필수**: [규정 문서 10종 수집](../../challenges/decisions.md#-d6-02-미확정-시-영향--poc-2-전체-지연-사유)

---

## 현재 상태

```
✅ 문서 업로드 및 임베딩 API
✅ Milvus 벡터 검색 (하이브리드: 벡터 + 키워드)
✅ RAG 스트리밍 응답 (SSE)
✅ 멀티테넌트 파티션 분리
✅ 내부 검색 API (/internal/v1/search)
✅ Redis 임베딩 캐시
❌ 행정 규정 문서 전용 청킹 전략 미구현
❌ 규정 버전 관리 없음
❌ 규정 개정 시 이전 버전 비활성화 미구현
❌ 출처 조항 번호 정밀 추출 미구현
```

---

## 개선 태스크

### TASK-RAG-01 행정 규정 문서 전용 청킹 전략

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (Q&A 품질 직결) |
| **예상 공수** | 3일 |
| **담당** | AI/ML 중급 |

#### 현재 vs 개선 청킹 전략

```python
# 현재: 고정 길이 청킹 (500 tokens)
# → 규정의 조항 경계를 무시하여 답변 품질 저하

# 개선: 행정 규정 구조 인식 청킹
# 규정 문서 계층 구조: 규정명 > 장 > 절 > 조 > 항 > 호

class AdminRegulationChunker:
    """
    행정 규정 문서 전용 청킹 클래스.
    조(Article) 단위로 분리하여 맥락 보존.
    """
    
    ARTICLE_PATTERN = re.compile(
        r'제\s*(\d+)\s*조\s*[\(\（]([^\)\）]+)[\)\）]',
        re.MULTILINE
    )
    CLAUSE_PATTERN = re.compile(r'^[①②③④⑤⑥⑦⑧⑨⑩]', re.MULTILINE)
    
    def chunk(self, text: str, doc_metadata: dict) -> list[dict]:
        """
        조(Article) 단위로 청킹 + 메타데이터 추가
        
        Returns:
            [
                {
                    "content": "제3조(연가 일수) ① ...",
                    "metadata": {
                        "regulation_name": "복무 규정",
                        "article_no": 3,
                        "article_title": "연가 일수",
                        "chapter": "제2장",
                        "effective_date": "2025-01-01",
                        "version": "3.2",
                        "doc_id": "REG-HR-001"
                    }
                }
            ]
        """
        chunks = []
        articles = self.ARTICLE_PATTERN.split(text)
        
        for i, article_text in enumerate(articles):
            chunk = {
                "content": f"제{article_no}조({article_title})\n{article_text}",
                "metadata": {
                    **doc_metadata,
                    "article_no": article_no,
                    "article_title": article_title,
                    "chunk_type": "article"
                }
            }
            chunks.append(chunk)
        
        return chunks
```

#### 완료 기준
- 조 경계로 정확히 분리된 청킹 확인
- Q&A 시 "제X조" 형태의 출처 조항 번호 반환

---

### TASK-RAG-02 규정 파티션 구조 설계

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 1일 |
| **담당** | AI/ML 중급 |

```python
# Milvus 파티션 구조 (규정 분류별)
REGULATION_PARTITIONS = {
    "regulation_hr":       "인사/복무 규정 (연가, 출장, 복무 등)",
    "regulation_finance":  "회계/예산 규정 (지출, 결산, 계약 등)",
    "regulation_general":  "행정업무 운영 규정 (공문서 서식 등)",
    "regulation_security": "정보보안 지침",
    "regulation_forms":    "서식/양식 규정",
    "qa_history":          "과거 Q&A 이력 (지식 베이스)"
}

# 파티션 생성 스크립트
async def create_regulation_partitions(milvus_client):
    for partition_name, description in REGULATION_PARTITIONS.items():
        await milvus_client.create_partition(
            collection_name="alli_poc_regulations",
            partition_name=partition_name
        )
```

#### 완료 기준
- 6개 파티션 생성 완료
- 규정 카테고리별 분리 검색 동작 확인

---

### TASK-RAG-03 규정 문서 버전 관리

| 항목 | 내용 |
|------|------|
| **우선순위** | P1 |
| **예상 공수** | 2일 |
| **담당** | AI/ML 중급 |

```python
# 규정 업로드 API 개선: 버전 관리 추가
@router.post("/regulations/upload")
async def upload_regulation(
    file: UploadFile,
    category: str,
    effective_date: date,
    version: str,
    replaces_doc_id: Optional[str] = None  # 개정 시 이전 문서 ID
):
    """
    규정 문서 업로드 + 이전 버전 비활성화
    """
    if replaces_doc_id:
        # 이전 버전 Milvus에서 soft-delete (is_active = False)
        await milvus_client.update_metadata(
            doc_id=replaces_doc_id,
            metadata={"is_active": False, "replaced_by": new_doc_id}
        )
    
    # 신규 문서 업로드 + 버전 메타데이터 포함
    doc_id = await upload_and_index(file, {
        "version": version,
        "effective_date": effective_date.isoformat(),
        "is_active": True,
        "replaces": replaces_doc_id
    })
    
    return {"doc_id": doc_id, "version": version, "status": "indexed"}
```

#### Milvus 메타데이터 스키마 추가

```python
# 규정 문서 필드 추가
regulation_fields = [
    FieldSchema("doc_id", DataType.VARCHAR, max_length=50),
    FieldSchema("regulation_name", DataType.VARCHAR, max_length=200),
    FieldSchema("article_no", DataType.INT64),
    FieldSchema("article_title", DataType.VARCHAR, max_length=200),
    FieldSchema("category", DataType.VARCHAR, max_length=50),     # hr/finance/general
    FieldSchema("version", DataType.VARCHAR, max_length=20),
    FieldSchema("effective_date", DataType.VARCHAR, max_length=10),
    FieldSchema("is_active", DataType.BOOL),                      # 버전 관리
    FieldSchema("content", DataType.VARCHAR, max_length=10000),
    FieldSchema("embedding", DataType.FLOAT_VECTOR, dim=768)
]
```

---

### TASK-RAG-04 공공기관 문서 형식 파서 통합

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 (admin-web 업로드 연동 필수) |
| **예상 공수** | 4일 |
| **담당** | AI/ML 중급 |

#### 지원 형식 및 파서 매핑

```python
# ai-rag/src/parsers/document_parser.py

from enum import Enum

class DocFormat(str, Enum):
    # 한컴오피스 계열
    HWP   = "hwp"
    HWPX  = "hwpx"
    CELL  = "cell"   # 한셀 (LibreOffice 변환)
    SHOW  = "show"   # 한쇼 (LibreOffice 변환)
    # Microsoft Office 계열
    DOCX  = "docx"
    DOC   = "doc"
    XLSX  = "xlsx"
    XLS   = "xls"
    PPTX  = "pptx"
    PPT   = "ppt"
    # 공통
    PDF   = "pdf"
    TXT   = "txt"
    RTF   = "rtf"
    # 이미지/스캔
    JPG   = "jpg"
    PNG   = "png"
    TIFF  = "tiff"


# MIME 타입 → 확장자 매핑 (admin-api 검증용)
ALLOWED_MIME_TYPES: dict[str, str] = {
    # 한컴오피스
    "application/x-hwp":                    "hwp",
    "application/hwp":                      "hwp",
    "application/vnd.hancom.hwp":           "hwp",
    "application/vnd.hancom.hwpx":          "hwpx",
    "application/vnd.hancom.cell":          "cell",
    "application/vnd.hancom.show":          "show",
    # Microsoft Office
    "application/msword":                   "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
    "application/vnd.ms-excel":             "xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    "application/vnd.ms-powerpoint":        "ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
    # 공통
    "application/pdf":                      "pdf",
    "text/plain":                           "txt",
    "application/rtf":                      "rtf",
    # 이미지/스캔
    "image/jpeg":                           "jpg",
    "image/png":                            "png",
    "image/tiff":                           "tiff",
}


async def parse_document(file: UploadFile) -> ParsedDocument:
    """
    공공기관 표준 문서 형식 통합 파서.
    확장자 기반으로 파서 자동 선택.
    """
    ext = file.filename.rsplit('.', 1)[-1].lower()
    content = await file.read()

    match ext:
        # ── 한컴오피스 계열 ──────────────────────────────
        case "hwp":
            text = await _parse_hwp(content)
            doc_type = "한글문서"

        case "hwpx":
            text = await _parse_hwpx(content)
            doc_type = "한글문서(XML)"

        case "cell" | "show":
            text = await _parse_via_libreoffice(content, ext)
            doc_type = "한셀" if ext == "cell" else "한쇼"

        # ── Microsoft Office 계열 ──────────────────────
        case "docx":
            text = await _parse_docx(content)
            doc_type = "Word문서"

        case "doc":
            text = await _parse_via_libreoffice(content, ext)
            doc_type = "Word문서(구버전)"

        case "xlsx":
            text = await _parse_xlsx(content)
            doc_type = "Excel문서"

        case "xls":
            text = await _parse_via_libreoffice(content, ext)
            doc_type = "Excel문서(구버전)"

        case "pptx":
            text = await _parse_pptx(content)
            doc_type = "PowerPoint"

        case "ppt":
            text = await _parse_via_libreoffice(content, ext)
            doc_type = "PowerPoint(구버전)"

        # ── 공통 형식 ────────────────────────────────────
        case "pdf":
            text = await _parse_pdf(content)
            doc_type = "PDF"

        case "txt":
            text = content.decode('utf-8', errors='replace')
            doc_type = "텍스트"

        case "rtf":
            text = await _parse_via_libreoffice(content, ext)
            doc_type = "RTF문서"

        # ── 이미지/스캔 문서 → PaddleOCR ────────────────
        case "jpg" | "jpeg" | "png" | "tif" | "tiff":
            text = await _parse_image_ocr(content)
            doc_type = "스캔이미지"

        case _:
            raise UnsupportedFormatError(f"지원하지 않는 형식: .{ext}")

    return ParsedDocument(text=text, doc_type=doc_type, source_ext=ext)


# ── 파서 구현체 ─────────────────────────────────────────────────────

async def _parse_hwp(content: bytes) -> str:
    """hwp5lib 1차 → LibreOffice 폴백"""
    try:
        import tempfile, os
        with tempfile.NamedTemporaryFile(suffix='.hwp', delete=False) as f:
            f.write(content)
            tmp_path = f.name
        result = subprocess.run(
            ['hwp5txt', tmp_path], capture_output=True, text=True, timeout=30
        )
        os.unlink(tmp_path)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout
    except Exception:
        pass
    return await _parse_via_libreoffice(content, 'hwp')

async def _parse_hwpx(content: bytes) -> str:
    """HWPX: ZIP 압축 해제 → XML 직접 파싱"""
    import zipfile, xml.etree.ElementTree as ET, io
    texts = []
    with zipfile.ZipFile(io.BytesIO(content)) as z:
        for name in z.namelist():
            if 'section' in name.lower() and name.endswith('.xml'):
                with z.open(name) as f:
                    tree = ET.parse(f)
                    for elem in tree.iter():
                        if elem.text and elem.text.strip():
                            texts.append(elem.text.strip())
    return '\n'.join(texts)

async def _parse_docx(content: bytes) -> str:
    """python-docx 기반 DOCX 파싱"""
    from docx import Document
    import io
    doc = Document(io.BytesIO(content))
    paragraphs = [p.text for p in doc.paragraphs if p.text.strip()]
    # 표(table) 내 텍스트도 추출
    for table in doc.tables:
        for row in table.rows:
            for cell in row.cells:
                if cell.text.strip():
                    paragraphs.append(cell.text.strip())
    return '\n'.join(paragraphs)

async def _parse_xlsx(content: bytes) -> str:
    """openpyxl 기반 XLSX 파싱 — 셀 값 순차 추출"""
    import openpyxl, io
    wb = openpyxl.load_workbook(io.BytesIO(content), read_only=True, data_only=True)
    texts = []
    for sheet in wb.worksheets:
        texts.append(f"[시트: {sheet.title}]")
        for row in sheet.iter_rows(values_only=True):
            row_text = ' | '.join(str(v) for v in row if v is not None)
            if row_text.strip():
                texts.append(row_text)
    return '\n'.join(texts)

async def _parse_pptx(content: bytes) -> str:
    """python-pptx 기반 PPTX 파싱 — 슬라이드 텍스트 추출"""
    from pptx import Presentation
    import io
    prs = Presentation(io.BytesIO(content))
    texts = []
    for i, slide in enumerate(prs.slides, 1):
        texts.append(f"[슬라이드 {i}]")
        for shape in slide.shapes:
            if hasattr(shape, 'text') and shape.text.strip():
                texts.append(shape.text.strip())
    return '\n'.join(texts)

async def _parse_pdf(content: bytes) -> str:
    """pdfplumber 기반 PDF 파싱"""
    import pdfplumber, io
    texts = []
    with pdfplumber.open(io.BytesIO(content)) as pdf:
        for page in pdf.pages:
            page_text = page.extract_text()
            if page_text:
                texts.append(page_text)
    return '\n'.join(texts)

async def _parse_via_libreoffice(content: bytes, ext: str) -> str:
    """LibreOffice Headless 변환 → TXT 추출 (범용 폴백)"""
    import tempfile, os
    with tempfile.TemporaryDirectory() as tmpdir:
        in_path = os.path.join(tmpdir, f'input.{ext}')
        with open(in_path, 'wb') as f:
            f.write(content)
        subprocess.run(
            ['libreoffice', '--headless', '--convert-to', 'txt:Text',
             in_path, '--outdir', tmpdir],
            capture_output=True, timeout=60
        )
        out_path = os.path.join(tmpdir, 'input.txt')
        if os.path.exists(out_path):
            with open(out_path, 'r', encoding='utf-8', errors='replace') as f:
                return f.read()
    raise ConversionError(f"LibreOffice 변환 실패: .{ext}")

async def _parse_image_ocr(content: bytes) -> str:
    """PaddleOCR 한국어 텍스트 인식"""
    from paddleocr import PaddleOCR
    import numpy as np
    from PIL import Image
    import io
    ocr = PaddleOCR(use_angle_cls=True, lang='korean')
    image = Image.open(io.BytesIO(content)).convert('RGB')
    result = ocr.ocr(np.array(image), cls=True)
    texts = [line[1][0] for line in result[0] if line[1][0].strip()]
    return '\n'.join(texts)
```

#### 필요 패키지 (requirements.txt 추가)

```
# 기존 (유지)
pymilvus>=2.5.0
langchain>=0.3.0
paddleocr>=2.8.0
paddlepaddle>=2.6.0

# 신규 추가 — 공공기관 문서 형식 지원
pyhwp>=0.1.0            # HWP 5.x 파싱
python-docx>=1.1.0      # DOCX 파싱
openpyxl>=3.1.0         # XLSX 파싱
python-pptx>=1.0.0      # PPTX 파싱
pdfplumber>=0.11.0      # PDF 파싱 (기존 PyMuPDF 보완)
Pillow>=10.0.0          # 이미지 처리 (OCR 전처리)
# LibreOffice: Docker에 apt install libreoffice 로 설치
```

---

### TASK-RAG-05 규정 Q&A 프롬프트 최적화

| 항목 | 내용 |
|------|------|
| **우선순위** | P0 |
| **예상 공수** | 2일 |
| **담당** | AI/ML 중급 |

```python
REGULATION_QA_PROMPT = """당신은 행정 규정 전문 어시스턴트입니다.
아래 규정 조항들을 바탕으로 질문에 정확하게 답변하세요.

[관련 규정 조항]
{retrieved_contexts}

[질문]
{question}

[답변 형식]
1. **핵심 답변**: 질문에 대한 직접적인 답변 (1~2문장)
2. **관련 규정**: 근거 조항 명시 (예: 복무규정 제X조)
3. **추가 확인 사항**: 상황에 따라 달라지는 경우 명시
4. **주의사항**: 예외 사항 또는 담당자 확인 필요 사항

※ 규정에 명시되지 않은 내용은 "규정에 명시되어 있지 않습니다. 담당 부서에 문의하세요"로 답변하세요.
※ 최신 개정 규정을 우선 적용하고 개정일을 명시하세요.
"""

DOCUMENT_COMPLIANCE_PROMPT = """당신은 행정 문서 규정 준수 검토 전문가입니다.
아래 규정을 기준으로 제출된 문서의 규정 위반 여부를 검토하세요.

[규정 기준]
{regulation_contexts}

[검토 대상 문서]
{document_text}

[검토 결과 형식]
{
  "is_compliant": true/false,
  "compliance_score": 0~100,
  "violations": [
    {
      "location": "문서의 어느 부분",
      "issue": "무엇이 위반인지",
      "rule_reference": "근거 규정 조항",
      "suggestion": "어떻게 수정해야 하는지"
    }
  ],
  "overall_comment": "전체 평가 의견"
}
"""
```

---

### TASK-RAG-05 Q&A 이력 학습 지식베이스 구축

| 항목 | 내용 |
|------|------|
| **우선순위** | P2 |
| **예상 공수** | 2일 |

```python
# Q&A 이력 자동 저장 및 재학습
@router.post("/qa/feedback")
async def save_qa_feedback(
    question: str,
    answer: str,
    rating: int,  # 1~5
    regulation_refs: list[str]
):
    """사용자 피드백 + Q&A 이력 → qa_history 파티션에 저장"""
    if rating >= 4:  # 좋은 답변만 학습 데이터로 저장
        await milvus_client.insert(
            partition="qa_history",
            data={
                "content": f"Q: {question}\nA: {answer}",
                "metadata": {"rating": rating, "refs": regulation_refs}
            }
        )
```

---

## 완료 체크리스트

```
□ TASK-RAG-01: 행정 규정 전용 청킹 클래스 구현 및 단위 테스트
□ TASK-RAG-02: Milvus 파티션 6개 생성 스크립트 및 마이그레이션
□ TASK-RAG-03: 규정 버전 관리 업로드 API + soft-delete 구현
□ TASK-RAG-04: 규정 Q&A 프롬프트 2종 (Q&A용, 문서점검용) 구현
□ TASK-RAG-05: Q&A 피드백 저장 API 구현 (P2)
□ 규정 문서 10종 이상 업로드 및 검색 테스트
□ 조항 번호 반환 E2E 테스트 (chat-web까지)
```
