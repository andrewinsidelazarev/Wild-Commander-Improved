"""Снимок клиентской области окна VDAC2 Emul без смены фокуса пользователя.

Старый ft812_dump.bmp стенда сохраняет только каждый шестой ИЗМЕНЁННЫЙ кадр,
поэтому на статичном просмотрщике может оставаться устаревшим бесконечно.
PrintWindow получает именно текущую поверхность, нарисованную FT812 DLL.
"""
import ctypes as C
from ctypes import wintypes as W
from PIL import Image


def capture(pid):
    u,g=C.WinDLL('user32',use_last_error=True),C.WinDLL('gdi32',use_last_error=True)
    callback=C.WINFUNCTYPE(W.BOOL,W.HWND,W.LPARAM)
    u.EnumWindows.argtypes=[callback,W.LPARAM]
    u.GetWindowThreadProcessId.argtypes=[W.HWND,C.POINTER(W.DWORD)]
    u.GetWindowTextW.argtypes=[W.HWND,W.LPWSTR,C.c_int]
    u.GetClientRect.argtypes=[W.HWND,C.POINTER(W.RECT)]
    u.GetDC.argtypes=[W.HWND]; u.GetDC.restype=W.HDC
    u.ReleaseDC.argtypes=[W.HWND,W.HDC]
    u.PrintWindow.argtypes=[W.HWND,W.HDC,W.UINT]
    g.CreateCompatibleDC.argtypes=[W.HDC];g.CreateCompatibleDC.restype=W.HDC
    g.CreateCompatibleBitmap.argtypes=[W.HDC,C.c_int,C.c_int];g.CreateCompatibleBitmap.restype=W.HBITMAP
    g.SelectObject.argtypes=[W.HDC,W.HANDLE];g.SelectObject.restype=W.HANDLE
    g.DeleteObject.argtypes=[W.HANDLE]
    g.DeleteDC.argtypes=[W.HDC]
    g.GetDIBits.argtypes=[W.HDC,W.HBITMAP,W.UINT,W.UINT,C.c_void_p,C.c_void_p,W.UINT]
    matches=[]
    @callback
    def each(hwnd,unused):
        owner=W.DWORD()
        u.GetWindowThreadProcessId(hwnd,C.byref(owner))
        name=C.create_unicode_buffer(512)
        u.GetWindowTextW(hwnd,name,len(name))
        if owner.value==pid and name.value=='VDAC2 Emul':matches.append(hwnd)
        return True
    u.EnumWindows(each,0)
    assert len(matches)==1,matches
    hwnd=matches[0]
    rect=W.RECT()
    assert u.GetClientRect(hwnd,C.byref(rect))
    width,height=rect.right,rect.bottom
    assert (width,height)==(1024,768),(width,height)
    dc=u.GetDC(hwnd)
    mem=g.CreateCompatibleDC(dc)
    bitmap=g.CreateCompatibleBitmap(dc,width,height)
    old=g.SelectObject(mem,bitmap)
    try:
        assert u.PrintWindow(hwnd,mem,1),'PrintWindow failed'
        class Header(C.Structure):
            _fields_=[('size',W.DWORD),('width',W.LONG),('height',W.LONG),
                      ('planes',W.WORD),('bits',W.WORD),('compression',W.DWORD),
                      ('image_size',W.DWORD),('xppm',W.LONG),('yppm',W.LONG),
                      ('used',W.DWORD),('important',W.DWORD)]
        header=Header(40,width,-height,1,32,0,0,0,0,0,0)
        raw=C.create_string_buffer(width*height*4)
        g.SelectObject(mem,old)
        assert g.GetDIBits(dc,bitmap,0,height,raw,C.byref(header),0)==height
        result=Image.frombuffer('RGBA',(width,height),raw.raw,'raw','BGRA',0,1).convert('RGB')
        assert result.getbbox(),'Empty VDAC2 client capture'
        return result
    finally:
        g.SelectObject(mem,old)
        g.DeleteObject(bitmap)
        g.DeleteDC(mem)
        u.ReleaseDC(hwnd,dc)
