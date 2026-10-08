import java.io.*;
import net.ghosthand.btaudio.Proto;
public final class Dump {
  public static void main(String[] a) throws Exception {
    InputStream in = new BufferedInputStream(new TimedIn(new FileInputStream(a[0]), 15000), 1<<16);
    OutputStream out = new FileOutputStream(a[1]);
    byte[] hs = new byte[Proto.HANDSHAKE_LEN];
    Proto.readFully(in, hs, 0, hs.length);
    Proto.Format f = Proto.parseHandshake(hs);
    System.out.println("format: codec=" + f.codec + " ch=" + f.channels + " rate=" + f.sampleRate);
    while (true) {
      byte[] h = new byte[Proto.CHUNK_HEADER_LEN];
      try { Proto.readFully(in, h, 0, h.length); } catch (Exception e) { break; }
      int type = Proto.u8(h, 0), len = Proto.u32(h, 4);
      if (type == Proto.CHUNK_END) break;
      byte[] p = new byte[len];
      try { Proto.readFully(in, p, 0, len); } catch (Exception e) { break; }
      if (type == Proto.CHUNK_AUDIO) out.write(p);
    }
    out.close(); in.close();
    System.out.println("wrote " + new File(a[1]).length() + " bytes");
  }
}
