# AutoCropTemplate.vpy
import vapoursynth as vs
core = vs.core

# Constants for better readability
MATRIX = {
    'RGB': 0,
    'BT709': 1,
    'UNSPEC': 2,
    'BT470BG': 5,
    'BT2020_NCL': 9
}

TRANSFER = {
    'BT709': 1,
    'BT470BG': 5,
    'ST2084': 16
}

PRIMARIES = {
    'BT709': 1,
    'BT470BG': 5,
    'BT2020': 9
}

# Load source
clip = core.lsmas.LWLibavSource(source=r"{input_file}", cachefile=r"{cache_file}")
props = clip.get_frame(0).props

# Determine matrix, transfer and primaries
matrix = props.get('_Matrix', MATRIX['UNSPEC'])
if matrix == MATRIX['UNSPEC'] or matrix >= 15:
    matrix = MATRIX['RGB'] if clip.format.id == vs.RGB24 else (
        MATRIX['BT709'] if clip.height > 576 else MATRIX['BT470BG']
    )

transfer = props.get('_Transfer', TRANSFER['BT709'])
if transfer <= 0 or transfer >= 19:
    transfer = (
        TRANSFER['BT470BG'] if matrix == MATRIX['BT470BG'] else
        TRANSFER['ST2084'] if matrix == MATRIX['BT2020_NCL'] else
        TRANSFER['BT709']
    )

primaries = props.get('_Primaries', PRIMARIES['BT709'])
if primaries <= 0 or primaries >= 23:
    primaries = (
        PRIMARIES['BT470BG'] if matrix == MATRIX['BT470BG'] else
        PRIMARIES['BT2020'] if matrix == MATRIX['BT2020_NCL'] else
        PRIMARIES['BT709']
    )

# Process video
clip = clip.resize.Bicubic(
    matrix_in=matrix,
    transfer_in=transfer,
    primaries_in=primaries,
    format=vs.RGB24
)
clip = clip.libp2p.Pack()
clip.set_output()