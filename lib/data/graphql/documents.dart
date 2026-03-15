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
    day(day: $day)
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
        node
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
        node
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
        node
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
        node
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
        node
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
        node
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

  static const dayBundle = r'''
query DayBundle($day: String!, $filesFirst: Int!, $runsFirst: Int!) {
  stories {
    day(day: $day)
  }
  files {
    day(day: $day, first: $filesFirst) {
      edges {
        node
      }
    }
  }
  runs {
    byDate(date: $day, first: $runsFirst) {
      edges {
        node
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
        node
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
        node
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
}
