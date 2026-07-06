import Foundation

enum EmbeddedMasterMapping {
    static let csv: String = #"""
instrument,paddle,pattern,liberlive_name,payload_hex,Midi Channel,Midi Program
Guitar,Front,1,Single Strum,eb444c5f5a5a5a5b5a5a,1,1
Guitar,Front,2,Basic Picking 1,eb444c5f5a5a5a585a5a,1,2
Guitar,Front,3,Basic Picking 2,eb444c5f5a5a5a595a5a,1,3
Guitar,Front,4,Basic Column 1,eb444c5f5a5a5a5f5a5a,1,4
Guitar,Front,5,Basic Column 2,eb444c5f5a5a5a5e5a5a,1,5
Guitar,Front,6,Subway,eb444c5f5a5a5b5b5a5a,1,6
Guitar,Front,7,Paper Plane,eb444c5f5a5a5b585a5a,1,7
Guitar,Front,8,Hotel,eb444c5f5a5a5b595a5a,1,8
Guitar,Front,9,Memory,eb444c5f5a5a5b5e5a5a,1,9
Guitar,Front,10,Remember,eb444c5f5a5a5b5f5a5a,1,10
Guitar,Front,11,Glance,eb444c5f5a5a5b5c5a5a,1,11
Guitar,Front,12,Trouble,eb444c5f5a5a5b5d5a5a,1,12
Guitar,Front,13,Honey,eb444c5f5a5a5b525a5a,1,13
Guitar,Front,14,Obsessed,eb444c5f5a5a5b535a5a,1,14
Guitar,Front,15,Lapse,eb444c5f5a5a5b515a5a,1,15
Guitar,Front,16,Family,eb444c5f5a5a5b575a5a,1,16
Guitar,Front,17,Kid,eb444c5f5a5a5b545a5a,1,17
Guitar,Front,18,Waltz,eb444c5f5a5a5b4e5a5a,1,18
Guitar,Front,19,Mortal,eb444c5f5a5a5b4c5a5a,1,19
Guitar,Front,20,Dairy,eb444c5f5a5a5b4d5a5a,1,20
Guitar,Front,21,Skyline,eb444c5f5a5a585b5a5a,1,21
Guitar,Front,22,Freedom,eb444c5f5a5a58585a5a,1,22
Guitar,Front,23,Verse,eb444c5f5a5a58595a5a,1,23
Guitar,Front,24,Away,eb444c5f5a5a585e5a5a,1,24
Guitar,Front,25,Strange,eb444c5f5a5a585c5a5a,1,25
Guitar,Front,26,Wind,eb444c5f5a5a585d5a5a,1,26
Guitar,Front,27,Apart,eb444c5f5a5a58525a5a,1,27
Guitar,Front,28,Luggage,eb444c5f5a5a58535a5a,1,28
Guitar,Front,29,Train,eb444c5f5a5a587a5a5a,1,29
Guitar,Front,30,After School,eb444c5f5a5a587b5a5a,1,30
Guitar,Front,31,Rock,eb444c5f5a5a587e5a5a,1,31
Guitar,Front,32,Old Town,eb444c5f5a5a587c5a5a,1,32
Guitar,Front,33,Nibble,eb444c5f5a5a595b5a5a,1,33
Guitar,Front,34,Heels,eb444c5f5a5a59585a5a,1,34
Guitar,Front,35,Juliet,eb444c5f5a5a59595a5a,1,35
Guitar,Front,36,Garden,eb444c5f5a5a595e5a5a,1,36
Guitar,Front,37,Battle,eb444c5f5a5a595f5a5a,1,37
Guitar,Front,38,Lemon,eb444c5f5a5a595c5a5a,1,38
Guitar,Front,39,Encounter,eb444c5f5a5a595d5a5a,1,39
Guitar,Front,40,Heartbeat,eb444c5f5a5a59525a5a,1,40
Guitar,Front,41,Journey,eb444c5f5a5a59535a5a,1,41
Guitar,Front,42,Waiting,eb444c5f5a5a59505a5a,1,42
Guitar,Front,43,Seasoned,eb444c5f5a5a59515a5a,1,43
Guitar,Front,44,Tide,eb444c5f5a5a59575a5a,1,44
Guitar,Front,45,Tipsy,eb444c5f5a5a59485a5a,1,45
Guitar,Front,46,Bell,eb444c5f5a5a59555a5a,1,46
Guitar,Front,47,Drug,eb444c5f5a5a594b5a5a,1,47
Guitar,Front,48,Moon,eb444c5f5a5a59495a5a,1,48
Guitar,Front,49,Wander,eb444c5f5a5a594e5a5a,1,49
Guitar,Front,50,Red Wine,eb444c5f5a5a594f5a5a,1,50
Guitar,Front,51,Sweep Cutting,eb444c5f5a5a59455a5a,1,51
Guitar,Rear,1,Single Strum,eb444c5f5a5b5a5b5a5a,1,52
Guitar,Rear,2,Basic Picking 1,eb444c5f5a5b5a585a5a,1,53
Guitar,Rear,3,Basic Picking 2,eb444c5f5a5b5a595a5a,1,54
Guitar,Rear,4,Basic Column 1,eb444c5f5a5b5a5f5a5a,1,55
Guitar,Rear,5,Basic Column 2,eb444c5f5a5b5a5e5a5a,1,56
Guitar,Rear,6,Subway,eb444c5f5a5b5b5b5a5a,1,57
Guitar,Rear,7,Paper Plane,eb444c5f5a5b5b585a5a,1,58
Guitar,Rear,8,Hotel,eb444c5f5a5b5b595a5a,1,59
Guitar,Rear,9,Memory,eb444c5f5a5b5b5e5a5a,1,60
Guitar,Rear,10,Remember,eb444c5f5a5b5b5f5a5a,1,61
Guitar,Rear,11,Glance,eb444c5f5a5b5b5c5a5a,1,62
Guitar,Rear,12,Trouble,eb444c5f5a5b5b5d5a5a,1,63
Guitar,Rear,13,Honey,eb444c5f5a5b5b525a5a,1,64
Guitar,Rear,14,Obsessed,eb444c5f5a5b5b535a5a,1,65
Guitar,Rear,15,Lapse,eb444c5f5a5b5b515a5a,1,66
Guitar,Rear,16,Family,eb444c5f5a5b5b575a5a,1,67
Guitar,Rear,17,Kid,eb444c5f5a5b5b545a5a,1,68
Guitar,Rear,18,Waltz,eb444c5f5a5b5b4e5a5a,1,69
Guitar,Rear,19,Mortal,eb444c5f5a5b5b4c5a5a,1,70
Guitar,Rear,20,Dairy,eb444c5f5a5b5b4d5a5a,1,71
Guitar,Rear,21,Skyline,eb444c5f5a5b585b5a5a,1,72
Guitar,Rear,22,Freedom,eb444c5f5a5b58585a5a,1,73
Guitar,Rear,23,Verse,eb444c5f5a5b58595a5a,1,74
Guitar,Rear,24,Away,eb444c5f5a5b585e5a5a,1,75
Guitar,Rear,25,Strange,eb444c5f5a5b585c5a5a,1,76
Guitar,Rear,26,Wind,eb444c5f5a5b585d5a5a,1,77
Guitar,Rear,27,Apart,eb444c5f5a5b58525a5a,1,78
Guitar,Rear,28,Luggage,eb444c5f5a5b58535a5a,1,79
Guitar,Rear,29,Train,eb444c5f5a5b587a5a5a,1,80
Guitar,Rear,30,After School,eb444c5f5a5b587b5a5a,1,81
Guitar,Rear,31,Rock,eb444c5f5a5b587e5a5a,1,82
Guitar,Rear,32,Old Town,eb444c5f5a5b587c5a5a,1,83
Guitar,Rear,33,Nibble,eb444c5f5a5b595b5a5a,1,84
Guitar,Rear,34,Heels,eb444c5f5a5b59585a5a,1,85
Guitar,Rear,35,Juliet,eb444c5f5a5b59595a5a,1,86
Guitar,Rear,36,Garden,eb444c5f5a5b595e5a5a,1,87
Guitar,Rear,37,Battle,eb444c5f5a5b595f5a5a,1,88
Guitar,Rear,38,Lemon,eb444c5f5a5b595c5a5a,1,89
Guitar,Rear,39,Encounter,eb444c5f5a5b595d5a5a,1,90
Guitar,Rear,40,Heartbeat,eb444c5f5a5b59525a5a,1,91
Guitar,Rear,41,Journey,eb444c5f5a5b59535a5a,1,92
Guitar,Rear,42,Waiting,eb444c5f5a5b59505a5a,1,93
Guitar,Rear,43,Seasoned,eb444c5f5a5b59515a5a,1,94
Guitar,Rear,44,Tide,eb444c5f5a5b59575a5a,1,95
Guitar,Rear,45,Tipsy,eb444c5f5a5b59485a5a,1,96
Guitar,Rear,46,Bell,eb444c5f5a5b59555a5a,1,97
Guitar,Rear,47,Drug,eb444c5f5a5b594b5a5a,1,98
Guitar,Rear,48,Moon,eb444c5f5a5b59495a5a,1,99
Guitar,Rear,49,Wander,eb444c5f5a5b594e5a5a,1,100
Guitar,Rear,50,Red Wine,eb444c5f5a5b594f5a5a,1,101
Guitar,Rear,51,Sweep Cutting,eb444c5f5a5b59455a5a,1,102
Piano,Front,1,Basic Column 2,eb444c5f5a5a5e595a5a,2,1
Piano,Front,2,Basic Arpeggio 2,eb444c5f5a5a5e5f5a5a,2,2
Piano,Front,3,Basic Column 1,eb444c5f5a5a5e5a5a5a,2,3
Piano,Front,4,Basic Arpeggio 1,eb444c5f5a5a5e5e5a5a,2,4
Piano,Front,5,Pipe,eb444c5f5a5a5e475a5a,2,5
Piano,Front,6,Embrace,eb444c5f5a5a5e425a5a,2,6
Piano,Front,7,Letter,eb444c5f5a5a5e5d5a5a,2,7
Piano,Front,8,Sunshine,eb444c5f5a5a5e455a5a,2,8
Piano,Front,9,Cloud Ladder,eb444c5f5a5a5e405a5a,2,9
Piano,Front,10,Courage,eb444c5f5a5a5e515a5a,2,10
Piano,Front,11,Attached,eb444c5f5a5a5e7b5a5a,2,11
Piano,Front,12,Moonlight,eb444c5f5a5a5e465a5a,2,12
Piano,Front,13,Past,eb444c5f5a5a5e4d5a5a,2,13
Piano,Front,14,Spark,eb444c5f5a5a5e445a5a,2,14
Piano,Front,15,Cotton,eb444c5f5a5a5e435a5a,2,15
Piano,Front,16,Hesitate,eb444c5f5a5a5e505a5a,2,16
Piano,Front,17,Dance Step,eb444c5f5a5a5e7a5a5a,2,17
Piano,Front,18,Warm Winter,eb444c5f5a5a5e415a5a,2,18
Piano,Front,19,Footprint,eb444c5f5a5a5e565a5a,2,19
Piano,Rear,1,Basic Column 2,eb444c5f5a5b5e595a5a,2,20
Piano,Rear,2,Basic Arpeggio 2,eb444c5f5a5b5e5f5a5a,2,21
Piano,Rear,3,Basic Column 1,eb444c5f5a5b5e5a5a5a,2,22
Piano,Rear,4,Basic Arpeggio 1,eb444c5f5a5b5e5e5a5a,2,23
Piano,Rear,5,Pipoe,eb444c5f5a5b5e475a5a,2,24
Piano,Rear,6,Embrace,eb444c5f5a5b5e425a5a,2,25
Piano,Rear,7,Letter,eb444c5f5a5b5e5d5a5a,2,26
Piano,Rear,8,Sunshine,eb444c5f5a5b5e455a5a,2,27
Piano,Rear,9,Cloud Ladder,eb444c5f5a5b5e405a5a,2,28
Piano,Rear,10,Courage,eb444c5f5a5b5e515a5a,2,29
Piano,Rear,11,Attached,eb444c5f5a5b5e7b5a5a,2,30
Piano,Rear,12,Moonlight,eb444c5f5a5b5e465a5a,2,31
Piano,Rear,13,Past,eb444c5f5a5b5e4d5a5a,2,32
Piano,Rear,14,Spark,eb444c5f5a5b5e445a5a,2,33
Piano,Rear,15,Cotton,eb444c5f5a5b5e435a5a,2,34
Piano,Rear,16,Hesitate,eb444c5f5a5b5e505a5a,2,35
Piano,Rear,17,Dance Step,eb444c5f5a5b5e7a5a5a,2,36
Piano,Rear,18,Warm Winter,eb444c5f5a5b5e425a5a,2,37
Piano,Rear,19,Footprint,eb444c5f5a5b5e565a5a,2,38
Bass,Front,1,Basic Bass,eb444c5f5a5a5f5b5a5a,3,1
Bass,Front,2,Basic Short Bass,eb444c5f5a5a5f585a5a,3,2
Bass,Front,3,Single Eighth Note,eb444c5f5a5a5f595a5a,3,3
Bass,Front,4,Eighth Note Legato,eb444c5f5a5a5f5e5a5a,3,4
Bass,Front,5,Triple Bass,eb444c5f5a5a5f4f5a5a,3,5
Bass,Front,6,Pop 1,eb444c5f5a5a5f515a5a,3,6
Bass,Front,7,Pop 2,eb444c5f5a5a5f565a5a,3,7
Bass,Front,8,Pop 3,eb444c5f5a5a5f575a5a,3,8
Bass,Front,9,Pop 4,eb444c5f5a5a5f545a5a,3,9
Bass,Front,10,Pop 5,eb444c5f5a5a5f4b5a5a,3,10
Bass,Front,11,Blues,eb444c5f5a5a5f495a5a,3,11
Bass,Rear,1,Basic Bass,eb444c5f5a5b5f5b5a5a,3,12
Bass,Rear,2,Basic Short Bass,eb444c5f5a5b5f585a5a,3,13
Bass,Rear,3,Single Eighth Note,eb444c5f5a5b5f595a5a,3,14
Bass,Rear,4,Eighth Note Legato,eb444c5f5a5b5f5e5a5a,3,15
Bass,Rear,5,Triple Bass,eb444c5f5a5b5f4f5a5a,3,16
Bass,Rear,6,Pop 1,eb444c5f5a5b5f515a5a,3,17
Bass,Rear,7,Pop 2,eb444c5f5a5b5f565a5a,3,18
Bass,Rear,8,Pop 3,eb444c5f5a5b5f575a5a,3,19
Bass,Rear,9,Pop 4,eb444c5f5a5b5f545a5a,3,20
Bass,Rear,10,Pop 5,eb444c5f5a5b5f4b5a5a,3,21
Bass,Rear,11,Blues,eb444c5f5a5b5f495a5a,3,22
Drums,Front,1,Pop 1,eb444d5f5a844d5a5a,4,1
Drums,Front,2,Pop 2,eb444d5f5ab24d5a5a,4,2
Drums,Front,3,Pop 3,eb444d5f5aa84d5a5a,4,3
Drums,Front,4,Pop 4,eb444d5f5aa64d5a5a,4,4
Drums,Front,5,Pop 5,eb444d5f5a5c425a5a,4,5
Drums,Front,6,Pop 6,eb444d5f5a70465a5a,4,6
Drums,Front,7,Pop 7,eb444d5f5a08465a5a,4,7
Drums,Front,8,Rock 1,eb444d5f5a4a425a5a,4,8
Drums,Front,9,Rock 2,eb444d5f5a40425a5a,4,9
Drums,Front,10,Rock 3,eb444d5f5a7e425a5a,4,10
Drums,Front,11,Rock 4,eb444d5f5a74425a5a,4,11
Drums,Front,12,Rock 5,eb444d5f5ad2425a5a,4,12
Drums,Front,13,Vocal 1,eb444d5f5a62425a5a,4,13
Drums,Front,14,Vocal 2,eb444d5f5a18425a5a,4,14
Drums,Front,15,Vocal 3,eb444d5f5a16425a5a,4,15
Drums,Front,16,Country 1,eb444d5f5a0c425a5a,4,16
Drums,Front,17,Blues 1,eb444d5f5a2e425a5a,4,17
Drums,Front,18,Blues 2,eb444d5f5a30425a5a,4,18
Drums,Front,19,Jazz 1,eb444d5f5a3a425a5a,4,19
Drums,Front,20,Funk 1,eb444d5f5a24425a5a,4,20
Drums,Front,21,Waltz 1,eb444d5f5a6e465a5a,4,21
Drums,Rear,1,Pop 1,eb444d5f5a844d5b5a5a,4,22
Drums,Rear,2,Pop 2,eb444d5f5ab24d5b5a5a,4,23
Drums,Rear,3,Pop 3,eb444d5f5aa84d5b5a5a,4,24
Drums,Rear,4,Pop 4,eb444d5f5aa64d5b5a5a,4,25
Drums,Rear,5,Pop 5,eb444d5f5a5c425b5a5a,4,26
Drums,Rear,6,Pop 6,eb444d5f5a70465b5a5a,4,27
Drums,Rear,7,Pop 7,eb444d5f5a08465b5a5a,4,28
Drums,Rear,8,Rock 1,eb444d5f5a4a425b5a5a,4,29
Drums,Rear,9,Rock 2,eb444d5f5a40425b5a5a,4,30
Drums,Rear,10,Rock 3,eb444d5f5a7e425b5a5a,4,31
Drums,Rear,11,Rock 4,eb444d5f5a74425b5a5a,4,32
Drums,Rear,12,Rock 5,eb444d5f5ad2425b5a5a,4,33
Drums,Rear,13,Vocal 1,eb444d5f5a62425b5a5a,4,34
Drums,Rear,14,Vocal 2,eb444d5f5a18425b5a5a,4,35
Drums,Rear,15,Vocal 3,eb444d5f5a16425b5a5a,4,36
Drums,Rear,16,Country 1,eb444d5f5a0c425b5a5a,4,37
Drums,Rear,17,Blues 1,eb444d5f5a2e425b5a5a,4,38
Drums,Rear,18,Blues 2,eb444d5f5a30425b5a5a,4,39
Drums,Rear,19,Jazz 1,eb444d5f5a3a425b5a5a,4,40
Drums,Rear,20,Funk 1,eb444d5f5a24425b5a5a,4,41
Drums,Rear,21,Waltz 1,eb444d5f5a6e465b5a5a,4,42
"""#
}
