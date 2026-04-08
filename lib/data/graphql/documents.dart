class GqlDocuments {
  static const login = r'''
mutation Login(
  $username: String!,
  $password: String!
) {
  auth {
    login(username: $username, password: $password) {
      accessToken
      tokenType
      expiresIn
      user {
        username
      }
    }
  }
}
''';

  static const me = r'''
query Me {
  auth {
    me {
      username
    }
  }
}
''';

  static const storiesDay = r'''
query StoriesDay($day: String!) {
  stories {
    day(day: $day) {
      story {
        date place names description food sport highlightImage keywords country latitude longitude
      }
      run {
        id name type distance movingTime elapsedTime averageSpeed maxSpeed totalElevationGain startDateLocal startTime source sourceLabel
      }
    }
  }
}
''';

  static const storiesList = r'''
query StoriesList($first: Int!, $after: String) {
  stories {
    list(first: $first, after: $after) {
      totalCount
      pageInfo {
        hasNextPage
        endCursor
      }
      edges {
        node {
          date place names description food sport highlightImage keywords country latitude longitude
        }
      }
    }
  }
}
''';

  static const saveDay = r'''
mutation SaveDay($day: String!, $input: StoryUpdateInput!) {
  stories {
    saveDay(day: $day, input: $input) {
      data
    }
  }
}
''';

  static const filesDay = r'''
query FilesDay($day: String!, $first: Int!) {
  files {
    day(day: $day, first: $first) {
      edges {
        node {
          path date favorite imageTags type size gps
        }
      }
    }
  }
}
''';

  static const filesList = r'''
query FilesList($first: Int!) {
  files {
    list(first: $first) {
      edges {
        node {
          path date favorite imageTags type size gps
        }
      }
    }
  }
}
''';

  static const filesUpload = r'''
mutation UploadFiles($date: String!, $files: [Upload!]!) {
  files {
    upload(date: $date, files: $files) {
      message
      uploadCount
      autoAssignedHighlight
      highlightImage
      files
    }
  }
}
''';

  static const filesImageInfo = r'''
query FilesImageInfo($path: String!) {
  files {
    imageInfo(path: $path)
  }
}
''';

  static const filesDeleteFile = r'''
mutation FilesDeleteFile($path: String!) {
  files {
    deleteFile(path: $path) {
      data
    }
  }
}
''';

  static const updateHighlight = r'''
mutation HighlightImage($input: String!) {
  files {
    updateHighlight(input: $input) {
      data
    }
  }
}
''';

  static const runsList = r'''
query RunsList($first: Int!) {
  runs {
    list(first: $first) {
      edges {
        node {
          id name type distance movingTime elapsedTime averageSpeed maxSpeed totalElevationGain startDateLocal summaryPolyline startTime source sourceLabel
        }
      }
    }
  }
}
''';

  static const runsByDate = r'''
query RunsByDate($date: String!, $first: Int!) {
  runs {
    byDate(date: $date, first: $first) {
      edges {
        node {
          id name type distance movingTime elapsedTime averageSpeed maxSpeed totalElevationGain startDateLocal summaryPolyline startTime source sourceLabel
        }
      }
    }
  }
}
''';

  static const runsMonthly = r'''
query RunsMonthly($first: Int!) {
  runs {
    monthly(first: $first) {
      edges {
        node {
          year month distance
        }
      }
    }
  }
}
''';

  static const runSummary = r'''
query RunSummary($runId: String!) {
  runs {
    summary(runId: $runId)
  }
}
''';

  static const runDetail = r'''
query RunDetail($runId: String!) {
  runs {
    detail(runId: $runId)
  }
}
''';

  static const searchImages = r'''
query SearchImages($input: SearchInput!, $first: Int!) {
  search {
    query(input: $input, first: $first) {
      edges {
        node
      }
      totalCount
    }
  }
}
''';

  static const calendarEvents = r'''
query CalendarEvents($date: String) {
  calendar {
    events(date: $date)
  }
}
''';

  static const calendarConnect = r'''
mutation CalendarConnect {
  calendar {
    connect {
      message
    }
  }
}
''';

  static const calendarSyncNow = r'''
mutation CalendarSyncNow {
  calendar {
    syncNow {
      message
    }
  }
}
''';

  static const systemDataSources = r'''
query SystemDataSources {
  system {
    dataSources {
      key
      name
      description
      status
      automated
      lastSyncAt
      detail
    }
  }
}
''';

  static const dayBundle = r'''
query DayBundle($day: String!, $filesFirst: Int!, $runsFirst: Int!) {
  stories {
    day(day: $day) {
      story {
        date place names description food sport highlightImage keywords country latitude longitude
      }
      run {
        id name type distance movingTime elapsedTime averageSpeed maxSpeed totalElevationGain startDateLocal startTime
      }
    }
  }
  files {
    day(day: $day, first: $filesFirst) {
      edges {
        node {
          path date favorite imageTags type size gps
        }
      }
    }
  }
  runs {
    byDate(date: $day, first: $runsFirst) {
      edges {
        node {
          id name type distance movingTime elapsedTime averageSpeed maxSpeed totalElevationGain startDateLocal summaryPolyline startTime
        }
      }
    }
  }
  health {
    dailyActivity(dateFrom: $day, dateTo: $day, first: 1) {
      edges {
        node {
          date moveMinutes caloriesKcal distanceM heartPoints heartMinutes stepCount avgWeightKg cyclingDurationMs walkingDurationMs runningDurationMs source sourceLabel
        }
      }
    }
  }
}
''';

  static const runBundle = r'''
query RunBundle($runId: String!) {
  runs {
    summary(runId: $runId)
    detail(runId: $runId)
  }
}
''';

  static const personSearch = r'''
query PersonSearch($query: String!, $first: Int!) {
  persons {
    search(query: $query, first: $first) {
      edges {
        node {
          id firstName lastName birthDate deathDate relation profession studyProgram languages email phone address notes biography photoPath
        }
      }
    }
  }
}
''';

  static const personPopular = r'''
query PersonPopular($first: Int!) {
  persons {
    popular(first: $first) {
      edges {
        node {
          id firstName lastName birthDate deathDate relation profession studyProgram languages email phone address notes biography photoPath
        }
      }
    }
  }
}
''';

  static const personDetailBundle = r'''
query PersonDetailBundle($personId: Int!) {
  faces {
    personFaces(personId: $personId, first: 24) {
      edges {
        node
      }
    }
    personImages(
      personId: $personId
      limit: 24
      page: 1
      pageSize: 24
      mode: "auto"
      first: 24
    ) {
      edges {
        node
      }
    }
  }
}
''';

  static const updatePerson = r'''
mutation UpdatePerson($personId: Int!, $input: PersonInput!) {
  persons {
    update(personId: $personId, input: $input) {
      data
    }
  }
}
''';

  static const createPerson = r'''
mutation CreatePerson($input: PersonInput!) {
  persons {
    create(input: $input) {
      data
    }
  }
}
''';

  static const uploadPersonPhoto = r'''
mutation UploadPersonPhoto($personId: Int!, $files: [Upload!]!) {
  persons {
    uploadPhoto(personId: $personId, files: $files) {
      data
    }
  }
}
''';

  static const chatComplete = r'''
mutation ChatComplete($messages: [ChatMessageInput!]!) {
  chat {
    complete(input: { messages: $messages }) {
      text
      dates
      cards
      images
      toolCalls
      charts
      maps
    }
  }
}
''';

  static const chatStream = r'''
subscription ChatStream($messages: [ChatMessageInput!]!) {
  chat {
    stream(input: { messages: $messages }) {
      eventType
      delta
      error
    }
  }
}
''';

  static const timelineWhenWasINear = r'''
query TimelineWhenWasINear($location: String!) {
  timeline {
    whenWasINear(location: $location) {
      location
      dates
      totalDays
      error
      boundingBox {
        latMin latMax lonMin lonMax
      }
    }
  }
}
''';

  static const timelineDay = r'''
query TimelineDay($date: String!) {
  timeline {
    polyline(date: $date) {
      lat lon timestamp
    }
    runs(date: $date) {
      id name type distanceMeters movingTimeSeconds summaryPolyline startTime
    }
    imageLocations(date: $date) {
      lat lon path
    }
    segments(date: $date) {
      id segmentType startTime endTime durationMinutes placeId placeName placeAddress placeLat placeLon activityType startLat startLon endLat endLon distanceMeters source
    }
  }
}
''';

  static const addManualVisit = r'''
mutation AddManualVisit(
  $date: String!,
  $startTime: String!,
  $endTime: String!,
  $placeName: String!
) {
  timeline {
    addManualVisit(
      date: $date,
      startTime: $startTime,
      endTime: $endTime,
      placeName: $placeName,
    ) {
      data
    }
  }
}
''';

  static const addManualActivity = r'''
mutation AddManualActivity(
  $date: String!,
  $startTime: String!,
  $endTime: String!,
  $activityType: ActivityTypeEnum!,
  $placeNameStart: String!,
  $placeNameEnd: String!
) {
  timeline {
    addManualActivity(
      date: $date,
      startTime: $startTime,
      endTime: $endTime,
      activityType: $activityType,
      placeNameStart: $placeNameStart,
      placeNameEnd: $placeNameEnd,
    ) {
      data
    }
  }
}
''';

  static const deleteManualVisit = r'''
mutation DeleteManualVisit($segmentId: Int!) {
  timeline {
    deleteManualVisit(segmentId: $segmentId) {
      message
    }
  }
}
''';

  static const dailyActivity = r'''
query DailyActivity($date: String!) {
  health {
    dailyActivity(dateFrom: $date, dateTo: $date, first: 1) {
      edges {
        node {
          date moveMinutes caloriesKcal distanceM heartPoints heartMinutes stepCount avgWeightKg cyclingDurationMs walkingDurationMs runningDurationMs source sourceLabel
        }
      }
    }
  }
}
''';
}
