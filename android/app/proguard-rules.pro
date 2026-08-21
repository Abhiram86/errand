# PDFBox (via read_pdf_text) optionally references a JPEG2000 decoder that
# is not bundled. JPX images in PDFs will fail to decode, which is fine for
# text extraction — suppress the missing-class error so R8 can shrink.
-dontwarn com.gemalto.jp2.JP2Decoder
